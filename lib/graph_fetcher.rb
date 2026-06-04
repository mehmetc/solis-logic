# frozen_string_literal: true

require 'http'
require 'set'

# Fetches an entity and its related graph from Virtuoso level by level,
# returning JSON-LD directly without RDF parsing overhead.
#
# @example
#   fetcher = GraphFetcher.new(
#     endpoint: 'http://localhost:8890/sparql',
#     prefix: {'odis' => 'https://data.odis.be/'}
#   )
#
#   result = fetcher.fetch(
#     entity_id: 'https://data.odis.be/archieven/AE5E-31E3-D03E-C280-311B5077AE9A',
#     entity_type: 'odis:Archief',
#     per_entity_depth: 2,
#     max_total_depth: 2,
#     language: 'nl'
#   )
#
class GraphFetcher
  DEFAULT_PREFIXES = {
    'rdf' => 'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
    'rdfs' => 'http://www.w3.org/2000/01/rdf-schema#'
  }.freeze

  Stats = Struct.new(
    :http_requests,
    :http_time_ms,
    :nodes_fetched,
    :nodes_embedded,
    :entities_queued,
    :cache_hits,
    keyword_init: true
  ) do
    def to_h
      super.merge(
        avg_request_ms: http_requests.positive? ? (http_time_ms / http_requests).round(2) : 0
      )
    end
  end

  attr_reader :stats

  def initialize(endpoint:, prefix: {}, timeout: 30)
    @endpoint = endpoint
    @namespace = prefix.values.first
    @prefixes = DEFAULT_PREFIXES.merge(prefix)
    @timeout = timeout
    reset_stats!
  end

  def reset_stats!
    @stats = Stats.new(
      http_requests: 0,
      http_time_ms: 0.0,
      nodes_fetched: 0,
      nodes_embedded: 0,
      entities_queued: 0,
      cache_hits: 0
    )
  end

  # Fetch an entity and its related graph with level-based batching.
  #
  # @param entity_id [String] The full URI of the entity
  # @param entity_type [String] The type (prefixed or full URI), e.g. 'odis:Archief'
  # @param per_entity_depth [Integer] Sub-depth for root entity fetch (default: 2)
  # @param max_total_depth [Integer] Maximum BFS distance from root (default: 10)
  # @param language [String] Language filter for literals (default: 'nl')
  # @param max_nodes [Integer] Cap on total nodes fetched to prevent runaway (default: 500)
  # @return [Hash, nil] Nested entity with embedded relations, or nil if not found
  def fetch(entity_id:, entity_type:, per_entity_depth: 2, max_total_depth: 10,
            language: 'nl', max_nodes: 500, property_depths: {})
    reset_stats!
    all_nodes = {}
    seen_iris = Set.new([entity_id])

    # Level 0: root entity with type-filtered query
    root_nodes = fetch_entity_with_depth(entity_id, entity_type, per_entity_depth, language)
    root_nodes.each do |id, node|
      if all_nodes.key?(id)
        merge_node_properties(all_nodes[id], node)
      else
        all_nodes[id] = node
        @stats.nodes_fetched += 1
      end
    end
    seen_iris.merge(root_nodes.keys)

    # {iri => arrival_property}: which property on the root linked to this IRI
    current_frontier = extract_iris_with_properties(root_nodes.values)
                         .reject { |iri, _| seen_iris.include?(iri) }
    seen_iris.merge(current_frontier.keys)
    @stats.entities_queued = 1 + current_frontier.size

    # Loop up to the highest effective depth across all property overrides
    loop_max = [max_total_depth, *property_depths.values].max
    (1..loop_max).each do |distance|
      break if current_frontier.empty?
      break if all_nodes.size >= max_nodes

      iris_to_fetch = current_frontier.keys.first(max_nodes - all_nodes.size)

      level_nodes = if per_entity_depth == 1
                      fetch_nodes_batch(iris_to_fetch, language)
                    else
                      # per_entity_depth > 1: fall back to per-entity fetching
                      iris_to_fetch.each_with_object({}) do |iri, acc|
                        fetch_entity_with_depth(iri, nil, per_entity_depth, language).each do |id, node|
                          if acc.key?(id)
                            merge_node_properties(acc[id], node)
                          else
                            acc[id] = node
                          end
                        end
                      end
                    end

      level_nodes.each do |id, node|
        if all_nodes.key?(id)
          merge_node_properties(all_nodes[id], node)
        else
          all_nodes[id] = node
          @stats.nodes_fetched += 1
        end
      end

      # Build next frontier: apply per-property depth limit (A1 per-hop)
      next_frontier = {}
      extract_iris_with_properties(level_nodes.values).each do |iri, prop|
        next if seen_iris.include?(iri)
        effective_max = property_depths.fetch(prop, max_total_depth)
        next if distance >= effective_max
        next_frontier[iri] = prop
      end

      seen_iris.merge(next_frontier.keys)
      @stats.entities_queued += next_frontier.size
      current_frontier = next_frontier
    end

    return nil if all_nodes.empty?

    build_result(entity_id, all_nodes.values)
  end

  private

  # Fetch a single entity with N levels of its properties
  def fetch_entity_with_depth(entity_id, entity_type, depth, language)
    collected_subjects = Set.new([entity_id])
    current_subjects = [entity_id]
    nodes = {}

    depth.times do |d|
      break if current_subjects.empty?

      result = if d.zero? && entity_type
                 fetch_root_level(current_subjects, entity_type, language)
               else
                 fetch_level(current_subjects, language)
               end

      break if result.nil? || result.empty?

      graph = extract_graph(result)
      graph.each do |node|
        id = node['@id']
        next unless id
        if nodes.key?(id)
          merge_node_properties(nodes[id], node)
        else
          nodes[id] = node.dup
        end
      end

      next_subjects = extract_object_iris(graph, collected_subjects)
      collected_subjects.merge(next_subjects)
      current_subjects = next_subjects.to_a
    end

    nodes
  end

  def fetch_nodes_batch(iris, language)
    result = fetch_level(iris.to_a, language)
    return {} if result.nil?

    nodes = {}
    extract_graph(result).each do |node|
      id = node['@id']
      next unless id
      if nodes.key?(id)
        merge_node_properties(nodes[id], node)
      else
        nodes[id] = node.dup
      end
    end
    nodes
  end

  # Returns {iri => short_property_name} for all outbound namespace IRIs in nodes.
  # When an IRI is reachable via multiple properties, the first encountered wins.
  def extract_iris_with_properties(nodes)
    result = {}
    nodes.each do |node|
      node.each do |key, value|
        next if key.start_with?('@')
        short_key = strip_namespace(key)
        Array(value).each do |v|
          case v
          when Hash
            iri = v['@id']
            result[iri] ||= short_key if iri&.start_with?(@namespace)
          when String
            result[v] ||= short_key if v.start_with?(@namespace)
          end
        end
      end
    end
    result
  end

  def extract_all_iris_from_nodes(nodes)
    iris = Set.new
    nodes.each do |node|
      node.each do |key, value|
        next if key.start_with?('@')
        Array(value).each do |v|
          case v
          when Hash
            iris << v['@id'] if v['@id']&.start_with?(@namespace)
          when String
            iris << v if v.start_with?(@namespace)
          end
        end
      end
    end
    iris
  end

  def fetch_root_level(subjects, entity_type, language)
    type_uri = expand_prefixed_uri(entity_type)
    values_clause = build_values_clause(subjects)

    query = <<~SPARQL
      #{prefix_declarations}

      CONSTRUCT {
        ?subject a <#{type_uri}> ;
                 ?property ?value .
      }
      WHERE {
        VALUES ?subject {
          #{values_clause}
        }
        ?subject a <#{type_uri}> ;
                 ?property ?value .
        #{property_filter}
        #{value_filter(language)}
      }
    SPARQL

    execute_query(query)
  end

  def fetch_level(subjects, language)
    return nil if subjects.empty?

    # Chunk large subject lists to avoid query size limits
    if subjects.size > 100
      fetch_chunked(subjects, language)
    else
      fetch_single_level(subjects, language)
    end
  end

  def fetch_single_level(subjects, language)
    values_clause = build_values_clause(subjects)

    query = <<~SPARQL
      #{prefix_declarations}

      CONSTRUCT {
        ?subject ?property ?value .
      }
      WHERE {
        VALUES ?subject {
          #{values_clause}
        }
        ?subject ?property ?value .
        #{property_filter}
        #{value_filter(language)}
      }
    SPARQL

    execute_query(query)
  end

  def fetch_chunked(subjects, language)
    results = subjects.each_slice(100).map do |chunk|
      fetch_single_level(chunk, language)
    end

    merge_results(results.compact)
  end

  def execute_query(query)
    puts query
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # IMPORTANT: request N-Triples, not JSON-LD.
    # Virtuoso's JSON-LD serializer silently truncates large CONSTRUCT
    # results (it caps the output well below the actual triple count),
    # which made related entities disappear and be rendered downstream as
    # unresolved { _id, id } stubs. N-Triples is serialized in full.
    response = HTTP
                 .timeout(@timeout)
                 .post(@endpoint, form: {
                   query: query,
                   format: 'application/n-triples'
                 })

    elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000
    @stats.http_requests += 1
    @stats.http_time_ms += elapsed_ms

    unless response.status.success?
      warn "SPARQL query failed: #{response.status} - #{response.body}"
      return nil
    end

    body = response.body.to_s
    return nil if body.empty?

    parse_ntriples(body)
  rescue HTTP::Error => e
    warn "HTTP error: #{e.message}"
    nil
  end

  # Parse an N-Triples document into the same shape the rest of this class
  # expects from JSON-LD: { '@graph' => [ { '@id' => ..., pred => value(s) } ] }.
  # IRI objects become { '@id' => uri }; literals become their (unescaped)
  # string value; repeated predicates collapse into an array.
  def parse_ntriples(body)
    nodes = {}

    body.each_line do |line|
      triple = parse_ntriple_line(line)
      next unless triple

      subject, predicate, object = triple
      node = (nodes[subject] ||= { '@id' => subject })
      add_ntriple_property(node, predicate, object)
    end

    { '@graph' => nodes.values }
  end

  # Splits a single N-Triples line into [subject, predicate, object].
  # Subject/predicate are returned as bare IRI strings; object is either
  # { '@id' => uri } for an IRI/blank node or a String for a literal.
  def parse_ntriple_line(line)
    line = line.strip
    return nil if line.empty? || line.start_with?('#')

    line = line.sub(/\s*\.\s*\z/, '')
    m = line.match(/\A(<[^>]*>|_:\S+)\s+(<[^>]*>)\s+(.+)\z/m)
    return nil unless m

    [strip_angle(m[1]), strip_angle(m[2]), parse_ntriple_object(m[3].strip)]
  end

  def parse_ntriple_object(raw)
    if raw.start_with?('<')
      { '@id' => strip_angle(raw) }
    elsif raw.start_with?('_:')
      { '@id' => raw }
    elsif raw.start_with?('"')
      m = raw.match(/\A"((?:[^"\\]|\\.)*)"/m)
      m ? unescape_ntriples(m[1]) : raw
    else
      raw
    end
  end

  def strip_angle(token)
    token.start_with?('<') ? token[1..-2] : token
  end

  def unescape_ntriples(str)
    str.gsub(/\\(u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8}|.)/) do
      esc = Regexp.last_match(1)
      case esc[0]
      when 'u', 'U' then [esc[1..].to_i(16)].pack('U')
      when 't' then "\t"
      when 'n' then "\n"
      when 'r' then "\r"
      when 'b' then "\b"
      when 'f' then "\f"
      else esc[0]
      end
    end
  end

  def add_ntriple_property(node, predicate, value)
    existing = node[predicate]
    if existing.nil?
      node[predicate] = value
    else
      node[predicate] = (existing.is_a?(Array) ? existing : [existing]) + [value]
    end
  end

  def prefix_declarations
    @prefixes.map { |prefix, uri| "PREFIX #{prefix}: <#{uri}>" }.join("\n")
  end

  def property_filter
    "FILTER(STRSTARTS(STR(?property), \"#{@namespace}\"))"
  end

  def value_filter(language)
    <<~FILTER.strip
      FILTER(
        isIRI(?value) ||
        (isLiteral(?value) && (LANG(?value) = "#{language}" || LANG(?value) = ""))
      )
    FILTER
  end

  def build_values_clause(subjects)
    subjects.map { |s| "<#{s}>" }.join("\n          ")
  end

  def expand_prefixed_uri(uri)
    return uri unless uri.include?(':') && !uri.start_with?('http')

    prefix, local = uri.split(':', 2)
    if @prefixes.key?(prefix)
      "#{@prefixes[prefix]}#{local}"
    else
      uri
    end
  end

  def extract_graph(result)
    return [] if result.nil?

    case result
    when Hash
      if result.key?('@graph')
        Array(result['@graph'])
      elsif result.key?('@id')
        [result]
      else
        []
      end
    when Array
      result
    else
      []
    end
  end

  def extract_object_iris(graph, already_collected)
    iris = Set.new

    graph.each do |node|
      node.each do |key, value|
        next if key.start_with?('@')

        Array(value).each do |v|
          case v
          when Hash
            # {"@id": "..."} reference
            iris << v['@id'] if v['@id'] && v['@id'].start_with?(@namespace)
          when String
            # Might be a compacted IRI in some contexts
            iris << v if v.start_with?(@namespace)
          end
        end
      end
    end

    iris - already_collected
  end

  def merge_results(results)
    return nil if results.empty?

    # Just combine all graphs
    graphs = results.flat_map { |r| extract_graph(r) }

    { '@graph' => graphs }
  end

  def build_result(root_node_id, graphs)
    # Deduplicate nodes by @id, merging properties
    nodes_by_id = {}

    graphs.each do |node|
      id = node['@id']
      next unless id

      if nodes_by_id.key?(id)
        merge_node_properties(nodes_by_id[id], node)
      else
        nodes_by_id[id] = node.dup
      end
    end

    # Embed related nodes and transform to API format
    embed_and_transform(nodes_by_id[root_node_id], nodes_by_id)
  end

  def merge_node_properties(target, source)
    source.each do |key, value|
      next if key == '@id'

      existing = target[key]
      if existing.nil?
        target[key] = value
      elsif existing != value
        target[key] = (Array(existing) + Array(value)).uniq
      end
    end
  end

  def embed_and_transform(node, all_nodes, in_progress = Set.new, cache = {})
    return nil if node.nil?

    id = node['@id']

    # Cycle: currently processing this node up the call stack
    return { '_id' => id, 'id' => extract_local_id(id) } if in_progress.include?(id)

    # Already fully transformed: return cached result
    if cache.key?(id)
      @stats.cache_hits += 1
      return cache[id]
    end

    in_progress.add(id)
    @stats.nodes_embedded += 1
    result = { '_id' => id, 'id' => extract_local_id(id) }

    node.each do |key, value|
      next if key.start_with?('@')

      short_key = strip_namespace(key)
      result[short_key] = transform_value(value, all_nodes, in_progress, cache)
    end

    in_progress.delete(id)
    cache[id] = result
    result
  end

  def extract_local_id(uri)
    return nil unless uri
    uri.split('/').last
  end

  def strip_namespace(uri)
    return uri unless uri.start_with?(@namespace)
    uri.sub(@namespace, '')
  end

  def transform_value(value, all_nodes, in_progress, cache)
    case value
    when Array
      value.map { |v| transform_value(v, all_nodes, in_progress, cache) }
    when Hash
      if value.key?('@id')
        # Reference to another node - embed it
        ref_id = value['@id']
        if all_nodes.key?(ref_id)
          embed_and_transform(all_nodes[ref_id], all_nodes, in_progress, cache)
        else
          # Unresolved reference - just return id info
          { '_id' => ref_id, 'id' => extract_local_id(ref_id) }
        end
      elsif value.key?('@value')
        # Language-tagged or typed literal - just return the value
        value['@value']
      else
        value
      end
    when String
      # Plain string URI - check if it's a reference we can embed
      if value.start_with?(@namespace) && all_nodes.key?(value)
        embed_and_transform(all_nodes[value], all_nodes, in_progress, cache)
      elsif value.start_with?(@namespace)
        # Unresolved reference
        { '_id' => value, 'id' => extract_local_id(value) }
      else
        value
      end
    else
      value
    end
  end
end