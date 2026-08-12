# solis-logic

Serverless-style "logic" endpoints for the Solis stack. This document focuses on
the **graph** logic — `GET /_logic/graph` — which returns an entity and its
related graph as nested JSON.

```
GET /_logic/graph?id=<id>&entity=<Type>&depth=<n>&language=<lang>
```

Example:

```
http://127.0.0.1:9293/_logic/graph?id=PS15-BD6C-8D9C-FAA0-873D204648PS&entity=Persoon&depth=3&language=nl
```

The handler lives in the config tree (`config.odis/logics/data/graph.rb`),
delegates to `Logic::Helper#resolve_graph` ([lib/logic_helper.rb](lib/logic_helper.rb)),
which drives [`GraphFetcher`](lib/graph_fetcher.rb).

---

## How the graph is traversed (BFS depth & budget)

`GraphFetcher#fetch` walks outward from the root entity **breadth-first**, one
distance level at a time, fetching each level from Virtuoso with a `CONSTRUCT`
query and embedding the results into a nested structure. A related node that is
reached but **not** fetched is rendered as a stub — just `{ "_id": …, "id": … }`
with no properties.

Whether a node gets expanded or left as a stub is governed by two independent
limits: a **per-hop depth budget** and a **node-count budget**.

### 1. Per-hop depth budget (`property_depth`)

Every property can have its own depth limit. The rule:

> A node at **distance `D`** from the root, reached via **property `P`**, is
> expanded iff `D ≤ effective_max(P)`, where
> `effective_max(P) = property_depth[P]` if `P` has an override, otherwise the
> global `depth` from the URL.

Distances are counted from the root:

```
root (0) ──verwantschap──▶ Verwantschap (1) ──agent──▶ Persoon (2) ──naam──▶ Naam (3) ──naamsoort──▶ Naamsoort (4) ──context──▶ Context (5)
```

`property_depth` is a per-hop **cap keyed on the property you arrive through** —
it is **not** a boost and **not** global. Two consequences worth internalising:

- **A low override blocks expansion.** If `context: 2` but a `context` node sits
  at distance 3 (`naam → naamsoort → context`), then `3 ≤ 2` is false, so it is
  never fetched — it stays a stub everywhere it appears. Raise it to `3`+ (or
  remove the override so it inherits the global `depth`) to expand it.
- **A low override stops recursion.** `verwantschap: 1` means a verwantschap node
  is fetched only at distance 1. The root's own verwantschap expands, but an
  agent-person's *own* verwantschap (distance 3) does not — which is exactly how
  you stop relationship chains from fanning out combinatorially.

Because codetables are shared, a node that is "too deep" on one path can still
appear expanded if the **same** node is reachable within budget via a shorter
path (e.g. `naamsoort`/`context` are reached cheaply through the root's own
`naam`, and the deep `verwantschap.agent.naam.naamsoort` then embeds the shared,
already-expanded copy).

Configured under the service role in `config.yml`:

```yaml
:services:
  :data_logic:
    :property_depth:
      verwantschap: 1
      naam: 4
      agent: 3
      relatie: 2
      context: 4
```

> ⚠️ `Solis::ConfigFile` reads `config.yml` **once at process start** and caches
> it. After editing `property_depth` you must **restart the service** for the
> change to take effect.

### 2. Node-count budget (breadth cap)

To keep large entities bounded, the traversal also caps how many nodes it
fetches, with two tiers so deep relationship chains are not starved by breadth:

- **`max_nodes`** (default 500) — ordinary breadth budget.
- **`max_priority_nodes`** (default `max_nodes * 4`) — a larger ceiling reserved
  for edges whose arrival property has a `property_depth` override. Those
  prioritized chains are fetched first and against the larger ceiling, so they
  reach their configured depth even when the ordinary budget is spent.

The depth analysis tool below models the **depth** dimension; the node budget is
reported only as a hint.

---

## Inspecting the traversal: `tools/graph_depth.rb`

A standalone analyzer that replays the exact per-hop rule for one entity and
shows, for every node it reaches, the distance, the arrival property, the
effective budget, and whether it expands or stubs. It reads its defaults
(endpoint, namespace, `property_depth`, language) from the same `config.yml` the
service uses.

```
ruby tools/graph_depth.rb --entity Persoon --id PS15-BD6C-8D9C-FAA0-873D204648PS --depth 3
```

Options:

| flag | meaning |
|------|---------|
| `--entity TYPE` | entity type, e.g. `Persoon` (required) |
| `--id ID` | local id or full IRI of the root (required) |
| `--depth N` | global depth (URL `depth`), clamped to 1..5 |
| `--path A.B.C` | trace a dotted property path and show the per-hop budget table |
| `--set k=v,k=v` | override `property_depth` for a what-if run (no config edit) |
| `--config PATH` | config.yml (default: `../config.odis/config.yml`) |
| `--role ROLE` | service role (default `data_logic`) |
| `--endpoint URL` / `--language LANG` | override config values |

### Example — why a node stays a stub

```
$ ruby tools/graph_depth.rb --entity Persoon --id PS15-BD6C-8D9C-FAA0-873D204648PS \
    --depth 3 --set context=2 --path verwantschap.agent.naam.naamsoort.context

property_depth : verwantschap=1  naam=4  agent=3  relatie=2  context=2
rule           : node at distance D via property P expands iff D <= effective_max(P)

Reached nodes by distance:
  distance   reached  expanded   stub
  0                1         1      0
  1               14        14      0
  2               17        17      0
  3              471        23    448
  4               12         0     12

Stub reasons (expansion stopped because distance > effective_max):
  property           effective_max   count  example
  verwantschap       1                 442  verwantschappen/75D4-… (at distance 3)
  datering           2                  12  dateringen_systematisch/D15B-… (at distance 3)
  context            2                   3  contexten/85D4-…       (at distance 3)
  naamsoort          3 (default)         2  naamsoorten/1066-…     (at distance 4)

Path trace: verwantschap.agent.naam.naamsoort.context
  hop            target                                   distance  eff_max  status
  verwantschap   verwantschappen/F357-…                          1        1  expanded
  agent          personen/PSBE-…                                 2        3  expanded
  naam           namen/PN2F-…                                    3        4  expanded
  naamsoort      naamsoorten/1003-…                              2        3  expanded
  context        contexten/84E6-…                                3        2  STUB (3 > 2)
```

`--set context=4` (or removing the override) flips that last row to `expanded`.

The `Stub reasons` block is the quickest way to answer "why is this not
expanded?": it groups every stub by the property that capped it, so you can see
at a glance which `property_depth` value (or the global default) to raise.

---

## Implementation notes

- **N-Triples, not JSON-LD.** `GraphFetcher` requests `application/n-triples`
  from Virtuoso. Virtuoso's JSON-LD serializer silently truncates large
  `CONSTRUCT` results (see [docs/virtuoso-jsonld-bug](docs/virtuoso-jsonld-bug)).
- **Single-valued references.** Property values are wrapped with `wrap_values`
  (never `Kernel#Array`, which would explode a single `{ "@id": … }` hash into
  key/value pairs and silently drop single-valued relations like `agent` or
  `context` from traversal).
