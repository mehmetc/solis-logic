# frozen_string_literal: true

require 'http'
require 'oj'
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

  # Fetch an entity and its related graph with per-entity depth
  #
  # @param entity_id [String] The full URI of the entity
  # @param entity_type [String] The type (prefixed or full URI), e.g. 'odis:Archief'
  # @param per_entity_depth [Integer] How many levels to fetch for each entity (default: 2)
  # @param max_total_depth [Integer] Maximum depth from root to stop fetching (default: 10)
  # @param language [String] Language filter for literals (default: 'nl')
  # @return [Hash, nil] Nested entity with embedded relations, or nil if not found
  def fetch(entity_id:, entity_type:, per_entity_depth: 2, max_total_depth: 10, language: 'nl')
    reset_stats!
    all_nodes = {}

    # Queue: [entity_id, entity_type_or_nil, distance_from_root]
    fetch_queue = [[entity_id, entity_type, 0]]
    queued = Set.new([entity_id])
    @stats.entities_queued = 1

    while (item = fetch_queue.shift)
      current_id, current_type, distance = item

      # Fetch this entity with per_entity_depth levels
      entity_nodes = fetch_entity_with_depth(current_id, current_type, per_entity_depth, language)

      # Merge into all_nodes
      entity_nodes.each do |id, node|
        if all_nodes.key?(id)
          merge_node_properties(all_nodes[id], node)
        else
          all_nodes[id] = node
          @stats.nodes_fetched += 1
        end
      end

      # Queue newly discovered entities (if within max_total_depth)
      next if distance >= max_total_depth

      new_iris = extract_all_iris_from_nodes(entity_nodes.values) - queued
      new_iris.each do |iri|
        fetch_queue << [iri, nil, distance + 1]
        queued << iri
        @stats.entities_queued += 1
      end
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
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    response = HTTP
                 .timeout(@timeout)
                 .post(@endpoint, form: {
                   query: query,
                   format: 'application/ld+json'
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

    Oj.load(body, mode: :compat)
  rescue HTTP::Error => e
    warn "HTTP error: #{e.message}"
    nil
  rescue Oj::ParseError => e
    warn "JSON parse error: #{e.message}"
    nil
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