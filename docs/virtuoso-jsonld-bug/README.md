# Virtuoso silently drops triples from `CONSTRUCT` results when serialized as JSON-LD

## Summary

A SPARQL `CONSTRUCT` query that returns *N* triples is serialized **completely** as
N-Triples / Turtle-line / CSV, and the equivalent `SELECT` returns all *N* solutions,
but the **`application/ld+json` (JSON-LD)** serialization of the *same* `CONSTRUCT`
silently returns **fewer** triples — dropping whole subjects from the output.

The response is HTTP `200`, well-formed, complete JSON (not a truncated byte stream),
and carries no error, warning, or partial-result indicator. The result simply contains
fewer triples than the query produced, so a client has no way to detect the loss.

In our case a 528-triple / 100-subject `CONSTRUCT` is returned as **428 triples / 95
subjects** in JSON-LD; 5 subjects vanish entirely. Downstream this made related
entities silently disappear from an API graph response.

## Environment

| | |
|---|---|
| Server header | `Virtuoso/08.03.3334 (Linux) x86_64-ubuntu_noble-linux-glibc2.39  VDB` |
| Endpoint | `POST /sparql` (form params `query`, `format`) |
| Request | `format=application/ld+json` vs `format=application/n-triples` |
| Response | HTTP 200, `Content-Type: application/ld+json`, complete/valid JSON |
| Timing | ~0.10 s (not a timeout / anytime-query cutoff) |

## Expected vs. actual

For one and the same `CONSTRUCT { ?s ?p ?o } WHERE { ... }`:

| Serialization | Triples returned | Distinct subjects | Correct? |
|---|---|---|---|
| `SELECT ?s ?p ?o` (cross-check) | **528** | **100** | — (ground truth) |
| `application/n-triples` | **528** | **100** | ✅ |
| `application/ld+json` | **428** | **95** | ❌ **5 subjects dropped** |

Expected: JSON-LD contains the same 528 triples / 100 subjects as every other
serialization. Actual: JSON-LD contains a deterministic subset.

## Self-contained reproduction

A loadable fixture is provided: [`fixture.nt`](./fixture.nt) — 528 N-Triples, 100
distinct subjects, mixed resource types (heterogeneous predicate sets per subject).

```sh
# 1. Load the fixture into a fresh graph
curl "$VIRTUOSO/sparql" \
  --data-urlencode "query=CLEAR GRAPH <urn:test:jsonld-bug>"
# Load fixture.nt into <urn:test:jsonld-bug> (e.g. via ld_dir / DB.DBA.TTLP_MT,
# isql, the /sparql-graph-crud endpoint, or batched INSERT DATA).

# 2. Ground truth — SELECT sees all triples
curl -s "$VIRTUOSO/sparql" \
  --data-urlencode "query=SELECT (COUNT(*) AS ?c) (COUNT(DISTINCT ?s) AS ?d)
                          WHERE { GRAPH <urn:test:jsonld-bug> { ?s ?p ?o } }" \
  --data-urlencode "format=application/sparql-results+json"
# -> c = 528, d = 100

# 3. CONSTRUCT as N-Triples — COMPLETE (528 triples, 100 subjects)
curl -s "$VIRTUOSO/sparql" \
  --data-urlencode "query=CONSTRUCT { ?s ?p ?o }
                          WHERE { GRAPH <urn:test:jsonld-bug> { ?s ?p ?o } }" \
  --data-urlencode "format=application/n-triples" | grep -c ' \.$'
# -> 528

# 4. CONSTRUCT as JSON-LD — TRUNCATED (428 triples, 95 nodes in @graph)
curl -s "$VIRTUOSO/sparql" \
  --data-urlencode "query=CONSTRUCT { ?s ?p ?o }
                          WHERE { GRAPH <urn:test:jsonld-bug> { ?s ?p ?o } }" \
  --data-urlencode "format=application/ld+json" \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin)['@graph']), 'nodes')"
# -> 95 nodes   (5 subjects missing entirely)
```

In our isolated reproduction the 5 dropped subjects were:

```
https://odis.q.libis.be/geografische_trefwoorden/10560000003312
https://odis.q.libis.be/geografische_trefwoorden/10560000003433
https://odis.q.libis.be/geografische_trefwoorden/10560000003522
https://odis.q.libis.be/geografische_trefwoorden/10560000003792
https://odis.q.libis.be/geografische_trefwoorden/12500000023045
```

The drop is deterministic for a given graph/plan (same subjects every run).

## Diagnostics — what we ruled out

- **Not a row limit.** `ResultSetMaxRows` and the `maxrows` request parameter have
  **no effect** on the JSON-LD output (tried `maxrows=0`, `100000`). A purely
  synthetic `CONSTRUCT` generating 2000 triples via `VALUES` serializes fully as
  JSON-LD, so there is no fixed triple cap.
- **Not output size / large literals.** Synthetic data with 500 KB of literals
  serializes fully. Capping every literal in the failing fixture to 200 characters
  **still drops the same number of subjects** — so literal length is not the trigger.
- **Not a timeout / anytime query.** Response completes in ~0.10 s with HTTP 200 and
  **no** partial-result header; raising execution-time limits changes nothing.
- **Not malformed/truncated bytes.** The JSON document is complete and parses cleanly;
  it simply contains fewer triples (smaller `@graph`).
- **Format-specific.** `SELECT`, `application/n-triples`, and `text/csv` of the same
  query all return the full 528 triples / 100 subjects. Only `application/ld+json`
  loses data. (Whether `text/turtle` / `application/rdf+xml` share the defect was not
  conclusively measured and is worth checking on your side.)
- **Data/structure dependent.** Uniform synthetic data (single predicate, or many
  distinct predicates, or large literals) does **not** trigger it. The bug reproduces
  with the heterogeneous fixture (100 subjects of several different types, each with a
  different set of predicates) read from the quad store. This points at the JSON-LD
  writer's per-subject grouping / `@context` construction over a heterogeneous result
  set rather than at literal content or result cardinality.

### Non-monotonic behavior (extra signal)

Reducing the input `VALUES` set does not monotonically reduce the loss, which is
inconsistent with a simple `LIMIT`/cap and again suggests a serializer-internal issue:

| Input subjects | JSON-LD triples returned |
|---|---|
| 90 | 481 (complete) |
| 91 | 501 (complete) |
| 92 | 484 (**truncated**) |
| 100 | 428 (**truncated**, 95 subjects) |

## Impact

JSON-LD is a common, standards-compliant SPARQL result format and is the natural choice
for clients that consume RDF as JSON. Because the loss is **silent** (HTTP 200, valid
JSON, no warning), any application relying on `CONSTRUCT` + `application/ld+json` can
silently lose data with no signal that anything went wrong. This is a correctness /
data-integrity issue, not merely a formatting nuisance.

## Workaround

Request a line-based RDF serialization (`application/n-triples`, or `SELECT ?s ?p ?o`)
and build the JSON client-side. We switched our fetcher from `application/ld+json` to
`application/n-triples` and the missing entities reappeared.

## Files in this report

- [`fixture.nt`](./fixture.nt) — 528 N-Triples, 100 subjects; load into any graph and
  run the `CONSTRUCT` above to reproduce.
