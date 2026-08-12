#!/usr/bin/env ruby
# frozen_string_literal: true
#
# graph_depth.rb — explain the BFS depth/budget traversal that the graph logic
# service (lib/graph_fetcher.rb) uses for a single root entity.
#
# It replays the fetcher's per-hop rule and reports, for every node it reaches:
#   - the BFS distance from the root,
#   - the property it arrived through,
#   - the effective depth budget for that property, and
#   - whether the node is expanded or left as a { _id, id } stub.
#
# The rule (identical to GraphFetcher#fetch):
#   A node at distance D, reached via property P, is EXPANDED iff
#       D <= effective_max(P)
#   where
#       effective_max(P) = property_depth[P]   if P has an override
#                          global depth         otherwise
#
#   property_depth is therefore a per-hop CAP keyed on the arrival property —
#   not a boost. Setting it BELOW a property's natural distance prevents
#   expansion (e.g. context:2 stubs a context that sits at distance 3).
#
# Note: this models the DEPTH dimension only. The live fetcher additionally
# applies a node-count budget (max_nodes / max_priority_nodes) that can cap
# breadth; that is reported as a hint but not enforced here.
#
# Usage:
#   ruby tools/graph_depth.rb --entity Persoon --id PS15-BD6C-8D9C-FAA0-873D204648PS --depth 3
#   ruby tools/graph_depth.rb --entity Persoon --id PS15-... --depth 3 \
#        --path verwantschap.agent.naam.naamsoort.context
#
# Defaults (endpoint, namespace, property_depth, language) are read from the
# service config.yml; override any of them with flags.

require 'optparse'
require 'yaml'
require 'set'
require 'stringio'
require 'http'
require_relative '../lib/graph_fetcher'

class DepthAnalyzer < GraphFetcher
  Info = Struct.new(:distance, :prop, :effective_max, :expanded, keyword_init: true)

  # Replays the fetcher's BFS, recording per-IRI distance/budget decisions.
  # @return [Array(Hash, Hash)] [info_by_iri, fetched_nodes_by_iri]
  def analyze(entity_id:, entity_type:, max_total_depth:, language:, property_depths:)
    reset_stats!
    info  = { entity_id => Info.new(distance: 0, prop: '(root)', effective_max: nil, expanded: true) }
    nodes = {}
    seen  = Set.new([entity_id])

    silence do
      root = fetch_entity_with_depth(entity_id, entity_type, 1, language)
      nodes.merge!(root)
      seen.merge(root.keys)

      # First frontier: the root's direct neighbours (always expanded — distance 1).
      frontier = extract_iris_with_properties(root.values).reject { |iri, _| seen.include?(iri) }
      frontier.each do |iri, prop|
        info[iri] = Info.new(distance: 1, prop: prop,
                             effective_max: property_depths.fetch(prop, max_total_depth),
                             expanded: true)
      end
      seen.merge(frontier.keys)

      loop_max = [max_total_depth, *property_depths.values].max
      (1..loop_max).each do |distance|
        break if frontier.empty?

        level = fetch_nodes_batch(frontier.keys, language)
        level.each { |id, n| nodes.key?(id) ? merge_node_properties(nodes[id], n) : (nodes[id] = n) }

        next_frontier = {}
        extract_iris_with_properties(level.values).each do |iri, prop|
          next if seen.include?(iri)
          emax     = property_depths.fetch(prop, max_total_depth)
          expanded = distance < emax            # child sits at distance+1, so (distance+1) <= emax
          if expanded
            info[iri] = Info.new(distance: distance + 1, prop: prop, effective_max: emax, expanded: true)
            next_frontier[iri] = prop
          else
            info[iri] ||= Info.new(distance: distance + 1, prop: prop, effective_max: emax, expanded: false)
          end
        end
        seen.merge(next_frontier.keys)
        frontier = next_frontier
      end
    end

    [info, nodes]
  end

  def namespace = @namespace

  private

  def silence
    orig = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = orig
  end
end

# ---- config + helpers -------------------------------------------------------

def kfetch(hash, key)
  return nil unless hash.is_a?(Hash)
  hash.fetch(key) { hash.fetch(key.to_s) { hash[key.to_sym] } }
end

def load_config(path, role)
  cfg   = YAML.load_file(path, aliases: true)
  svc   = kfetch(kfetch(cfg, :services), role) or abort "No service role :#{role} in #{path}"
  solis = kfetch(svc, :solis) || {}
  graphs = kfetch(solis, :graphs) || []
  main   = graphs.find { |g| kfetch(g, :type) == :main } || graphs.first || {}
  {
    endpoint:        kfetch(solis, :sparql_endpoint),
    graph:           kfetch(main, :name),
    prefix:          kfetch(main, :prefix),
    property_depths: (kfetch(svc, :property_depth) || {}).transform_keys(&:to_s),
    language:        kfetch(solis, :language) || kfetch(cfg, :language) || 'nl'
  }
end

def resolve_root_iri(endpoint, graph, entity_type, id)
  return id if id.start_with?('http')
  type_iri = "#{graph}#{entity_type}"
  q = %(SELECT ?s WHERE { ?s a <#{type_iri}> . FILTER(STRENDS(STR(?s), "/#{id}")) } LIMIT 2)
  resp = HTTP.timeout(30).post(endpoint, form: { query: q, format: 'text/csv' })
  rows = resp.body.to_s.lines.map { |l| l.strip.delete('"') }.reject(&:empty?)
  rows.shift # CSV header
  rows.first
end

def first_iri(value, namespace)
  Array(value.is_a?(Array) ? value : [value]).each do |v|
    iri = v.is_a?(Hash) ? v['@id'] : v
    return iri if iri.is_a?(String) && iri.start_with?(namespace)
  end
  nil
end

def short(iri, namespace) = iri ? iri.sub(namespace, '') : '(nil)'

def clip(str, width) = str.length > width ? "#{str[0, width - 1]}…" : str

# ---- CLI --------------------------------------------------------------------

opts = {
  config: File.expand_path('../../config.odis/config.yml', __dir__),
  role:   :data_logic,
  depth:  1
}
OptionParser.new do |o|
  o.banner = 'Usage: ruby tools/graph_depth.rb --entity TYPE --id ID [--depth N] [options]'
  o.on('--entity TYPE', 'Entity type, e.g. Persoon')                    { |v| opts[:entity] = v }
  o.on('--id ID', 'Local id or full IRI of the root')                   { |v| opts[:id] = v }
  o.on('--depth N', Integer, 'Global depth (URL depth param)')          { |v| opts[:depth] = v }
  o.on('--path A.B.C', 'Trace a dotted property path through the graph') { |v| opts[:path] = v }
  o.on('--set LIST', 'Override property_depth, e.g. context=2,verwantschap=4') { |v| opts[:set] = v }
  o.on('--config PATH', 'config.yml path')                              { |v| opts[:config] = v }
  o.on('--role ROLE', 'Service role (default data_logic)')              { |v| opts[:role] = v.to_sym }
  o.on('--endpoint URL', 'Override SPARQL endpoint')                    { |v| opts[:endpoint] = v }
  o.on('--language LANG', 'Override language')                          { |v| opts[:language] = v }
  o.on('-h', '--help') { puts o; exit }
end.parse!

abort 'Missing --entity' unless opts[:entity]
abort 'Missing --id'     unless opts[:id]

cfg = load_config(opts[:config], opts[:role])
endpoint = opts[:endpoint] || cfg[:endpoint] or abort 'No SPARQL endpoint (config or --endpoint)'
language = opts[:language] || cfg[:language]
graph    = cfg[:graph]
prefix   = cfg[:prefix]
pd       = cfg[:property_depths].dup
if opts[:set]
  opts[:set].split(',').each do |pair|
    k, v = pair.split('=', 2)
    pd[k.strip] = v.to_i
  end
end
depth    = [[opts[:depth], 1].max, 5].min   # same clamp as resolve_graph

root_iri = resolve_root_iri(endpoint, graph, opts[:entity], opts[:id]) or
  abort "Could not resolve root IRI for #{opts[:entity]} #{opts[:id]} (not found at #{endpoint})"

analyzer = DepthAnalyzer.new(endpoint: endpoint, prefix: { prefix => graph })
info, nodes = analyzer.analyze(
  entity_id:       root_iri,
  entity_type:     "#{prefix}:#{opts[:entity]}",
  max_total_depth: depth,
  language:        language,
  property_depths: pd
)
ns = analyzer.namespace

# ---- report -----------------------------------------------------------------

puts 'BFS depth analysis — graph logic'
puts '=' * 60
puts "endpoint       : #{endpoint}"
puts "namespace      : #{ns}"
puts "entity         : #{prefix}:#{opts[:entity]}  (#{opts[:id]})"
puts "root IRI       : #{root_iri}"
puts "global depth   : #{depth}"
puts "property_depth : #{pd.map { |k, v| "#{k}=#{v}" }.join('  ')}"
puts 'rule           : node at distance D via property P expands iff D <= effective_max(P);'
puts "                 effective_max(P) = property_depth[P] or #{depth} (global) if no override"
puts

# Distance histogram
by_distance = Hash.new { |h, k| h[k] = { reached: 0, expanded: 0, stub: 0 } }
info.each_value do |i|
  b = by_distance[i.distance]
  b[:reached] += 1
  i.expanded ? b[:expanded] += 1 : b[:stub] += 1
end
puts 'Reached nodes by distance:'
puts format('  %-9s %8s %9s %6s', 'distance', 'reached', 'expanded', 'stub')
by_distance.keys.sort.each do |d|
  b = by_distance[d]
  puts format('  %-9d %8d %9d %6d', d, b[:reached], b[:expanded], b[:stub])
end
tot = info.size
exp = info.count { |_, i| i.expanded }
puts format('  %-9s %8d %9d %6d', 'total', tot, exp, tot - exp)
puts

# Stub reasons grouped by (property, effective_max)
stubs = info.select { |_, i| !i.expanded }
unless stubs.empty?
  puts 'Stub reasons (expansion stopped because distance > effective_max):'
  puts format('  %-18s %-14s %6s  %s', 'property', 'effective_max', 'count', 'example')
  stubs.group_by { |_, i| [i.prop, i.effective_max] }
       .sort_by { |_, v| -v.size }
       .each do |(prop, emax), entries|
    iri, i = entries.first
    overridden = pd.key?(prop) ? '' : ' (default)'
    puts format('  %-18s %-14s %6d  %s (at distance %d)',
                prop, "#{emax}#{overridden}", entries.size, short(iri, ns), i.distance)
  end
  puts
end

# Optional path trace
if opts[:path]
  fmt = '  %-14s %-40s %8s %8s  %s'
  puts "Path trace: #{opts[:path]}"
  puts format(fmt, 'hop', 'target', 'distance', 'eff_max', 'status')
  cur = root_iri
  opts[:path].split('.').each do |prop|
    node = nodes[cur]
    if node.nil?
      puts format(fmt, prop, '(parent is a stub)', '-', '-', 'unreachable')
      break
    end
    child = first_iri(node["#{ns}#{prop}"], ns)
    if child.nil?
      puts format(fmt, prop, '(absent in data)', '-', '-', '—')
      break
    end
    i = info[child]
    note = i&.expanded ? 'expanded' : "STUB (#{i&.distance} > #{i&.effective_max})"
    puts format(fmt, prop, clip(short(child, ns), 40), i&.distance, i&.effective_max, note)
    break unless i&.expanded
    cur = child
  end
end
