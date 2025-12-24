require 'concurrent'
require_relative 'graph_fetcher'

module Logic
  module Helper
    private

    def api_error(status, source, title = "Unknown error", detail = "")
      { "errors": [{
                     "status": status,
                     "source": { "pointer": source },
                     "title": title,
                     "detail": detail
                   }] }.to_json
    end

    def required_parameters(params, required)
      if required.is_a?(Array)
        raise RuntimeError, api_error('400', '', "Missing parameter", "Missing parameter: one of #{required.join(', ')} is needed") unless (required.map(&:to_s) - params.keys.map(&:to_s)).empty?
      else
        raise RuntimeError, api_error('400', '', "Missing parameter", "Missing #{required.to_s} parameter") unless params.keys.map(&:to_s).include?(required.to_s)
      end
    rescue StandardError => e
      Solis::LOGGER.error('Unable to check required parameters')
      raise e
    end

    def resolve_graph(ids:, entity_type:, depth: 1)
      raise 'Please supply one or more uuid\'s' if ids.nil? || ids.empty?

      result = {}

      key = Digest::SHA256.hexdigest("#{entity_type}-#{ids}")
      result = cache[key] if cache.key?(key)

      graph = Solis::Options.instance.get[:graphs].select{|s| s['type'].eql?(:main)}&.first['name']
      prefix = Solis::Options.instance.get[:graphs].select{|s| s['type'].eql?(:main)}&.first['prefix']
      language = Graphiti.context[:object].language || Solis::Options.instance.get[:language] || 'en'
      fetcher = GraphFetcher.new(endpoint: Solis::Options.instance.get[:sparql_endpoint], prefix: {prefix => graph})

      depth = 5 if depth > 5
      depth = 1 if depth < 1

      ids = ids.gsub(/[^a-zA-Z0-9\-\,]/, '').split(',').map { |m| "#{graph}#{entity_type.tableize}/#{m}" }

      ids.each do |entity_id|
        result[entity_id] = fetcher.fetch(entity_id: entity_id,
                                          entity_type: "#{prefix}:#{entity_type}",
                                          per_entity_depth: 1,
                                          max_total_depth: 2,
                                          language: language)
      end
      cache.store(key, result, expires: 86400)

      result
    rescue StandardError => e
      puts e.message
      raise e
    end

    def resolve(filename, id_name, entity, ids, from_cache = '1', offset = 0, limit = 10, depth = 1)
      raise 'Please supply one or more uuid\'s' if ids.nil? || ids.empty?

      result = {}

      key = Digest::SHA256.hexdigest("#{entity}-#{ids}")
      result = cache[key] if cache.key?(key)
      graph_name = Solis::Options.instance.get[:graphs].select{|s| s['type'].eql?(:main)}&.first['name']
      graph_prefix = Solis::Options.instance.get[:graphs].select{|s| s['type'].eql?(:main)}&.first['prefix']

      if result.nil? || result.empty? || (from_cache.eql?('0'))
        model = $SOLIS.shape_as_model(entity)
        target_classes = target_class_for(model)
        ids = ids.gsub(/[^a-zA-Z0-9\-\,]/, '')
        if filename.empty?
          ids = ids.split(',').map { |m| "<#{graph_name}#{entity.tableize}/#{m}>" }
        else
          ids = ids.split(',').map { |m| target_classes.map { |target_class| "<#{target_class}/#{m}>" } }
        end
        ids = [ids] unless ids.is_a?(Array)
        ids = ids.join(" ")
        language = Graphiti.context[:object].language

        f = File.read(filename) unless filename.empty?
        #f = make_construct_old(ids,entity, {"#{graph_prefix}" => graph_name, "rdf" => "http://www.w3.org/1999/02/22-rdf-syntax-ns#"}, depth) if f.nil?
        f = make_construct(ids,entity, {"#{graph_prefix}" => graph_name, "rdf" => "http://www.w3.org/1999/02/22-rdf-syntax-ns#"}, depth) if f.nil?
        #f = make_virtuoso_construct(ids, entity, {"#{graph_prefix}" => graph_name, "rdf" => "http://www.w3.org/1999/02/22-rdf-syntax-ns#"}, depth) if f.nil?

        q = f.gsub(/{ ?{ ?VALUES ?} ?}/, "VALUES ?#{id_name} { #{ids} }")
             .gsub(/{ ?{ ?LANGUAGE ?} ?}/, "bind(\"#{language}\" as ?filter_language).")
             .sub(/{ ?{ ?ENTITY ?} ?}/, entity)
             .sub(/{ ?{ ?GRAPH ?} ?}/, graph_name)
             .sub(/{ ?{ ?OFFSET ?} ?}/, offset.to_i.to_s)
             .sub(/{ ?{ ?LIMIT ?} ?}/, limit.to_i.to_s)

        result = Solis::Query.run(entity, q, {model: model, max_embed_depth: depth})
        cache.store(key, result, expires: 86400)
      end
      result
    rescue StandardError => e
      puts e.message
      raise e
    end

    def cache
      @cache ||= Moneta.new(:File, dir: Solis::ConfigFile[:cache], expires: 86400)
    end

    private

    def target_class_for(model)
      descendants = ObjectSpace.each_object(Class).select { |klass| klass < model }.reject { |m| m.metadata.nil? }.map { |m| "#{Solis::Options.instance.get[:graph_name]}#{m.name.tableize}" }
      descendants << "#{Solis::Options.instance.get[:graph_name]}#{model.name.tableize}"
      descendants
    end

    def make_construct_old(entity_id, entity_name, prefixes = {}, depth = 1)
      language = Graphiti.context[:object].language || 'en'
      graph = Solis::Options.instance.get[:graphs].select{|s| s['type'].eql?(:main)}&.first['name']
      prefix = Solis::Options.instance.get[:graphs].select{|s| s['type'].eql?(:main)}&.first['prefix']

      # Build PREFIX declarations
      prefix_block = prefixes.map { |key, uri| "PREFIX #{key}: <#{uri}>" }.join("\n")
      prefix_block += "\nPREFIX #{prefix}: <#{graph}>" unless prefixes.keys.include?(prefix.to_s)

      # Start building CONSTRUCT and WHERE clauses
      construct_patterns = []
      where_unions = []

      # Build patterns for each depth level
      (0..depth).each do |level|
        # Variables for this level
        vars = (0..level).map { |i| "?value#{i}" }
        prop_vars = (0..level-1).map { |i| "?property#{i}" }

        # CONSTRUCT pattern for this level
        if level == 0
          construct_patterns << "?entity_id a #{prefix}:#{entity_name} ;\n           ?property ?value0 ."
        else
          prev_var = level == 1 ? "?value0" : "?value#{level-1}"
          construct_patterns << "#{prev_var} ?property#{level-1} ?value#{level} ."
        end

        # WHERE pattern for this level (as a UNION block)
        where_clause = []
        where_clause << "VALUES ?entity_id {#{entity_id}}"
        where_clause << "BIND(\"#{language}\" as ?filter_language) ."
        where_clause << "?entity_id a #{prefix}:#{entity_name} ;\n         ?property ?value0 ."
        where_clause << "FILTER(STRSTARTS(STR(?property), \"#{graph}\")) ."

        # Add language filter for level 0
        where_clause << "FILTER(\n      isIRI(?value0) ||\n      (isLiteral(?value0) && (\n        LANG(?value0) = ?filter_language || LANG(?value0) = \"\"\n      ))\n    )"

        # Add patterns for intermediate levels
        (1..level).each do |i|
          prev_var = "?value#{i-1}"
          curr_var = "?value#{i}"
          prop_var = "?property#{i-1}"

          where_clause << "FILTER(isIRI(#{prev_var})) ."
          where_clause << "#{prev_var} #{prop_var} #{curr_var} ."
          where_clause << "FILTER(STRSTARTS(STR(#{prop_var}), \"#{graph}\")) ."

          # Add language filter for this level
          where_clause << "FILTER(\n      isIRI(#{curr_var}) ||\n      (isLiteral(#{curr_var}) && (\n        LANG(#{curr_var}) = ?filter_language || LANG(#{curr_var}) = \"\"\n      ))\n    )"
        end

        # Add this level's WHERE clause to the UNION blocks
        where_unions << where_clause.join("\n    ")
      end

      # Combine everything into the final query
      query = <<~SPARQL
        #{prefix_block}

        CONSTRUCT {
          #{construct_patterns.join("\n  ")}
        }
        WHERE {
          #{where_unions.map { |union| "{\n    #{union}\n  }" }.join("\n  UNION\n  ")}
        }
      SPARQL
      query
    end

    def make_construct(entity_ids, entity_name, prefixes = {}, depth = 1)
      # Normalize entity_ids to always be an array
      entity_ids = entity_ids.split(' ')

      language = Graphiti.context[:object].language || Solis::Options.instance.get[:language] || 'en'
      graph = Solis::Options.instance.get[:graphs].select{|s| s['type'].eql?(:main)}&.first['name']
      prefix = Solis::Options.instance.get[:graphs].select{|s| s['type'].eql?(:main)}&.first['prefix']

      # Build PREFIX declarations
      prefix_block = prefixes.map { |key, uri| "PREFIX #{key}: <#{uri}>" }.join("\n")
      prefix_block += "\nPREFIX #{prefix}: <#{graph}>" unless prefixes.keys.include?(prefix.to_s)

      # Build VALUES clause with all entity IDs
      values_clause = entity_ids.map { |id| "<#{id.gsub(/[<>]/,'')}>" }.join("\n    ")

      # Start building CONSTRUCT and WHERE clauses
      construct_patterns = []
      where_unions = []

      # Build patterns for each depth level
      (0..depth).each do |level|
        # Variables for this level
        vars = (0..level).map { |i| "?value#{i}" }
        prop_vars = (0..level-1).map { |i| "?property#{i}" }

        # CONSTRUCT pattern for this level
        if level == 0
          construct_patterns << "?entity_id a #{prefix}:#{entity_name} ;\n           ?property ?value0 ."
        else
          prev_var = level == 1 ? "?value0" : "?value#{level-1}"
          construct_patterns << "#{prev_var} ?property#{level-1} ?value#{level} ."
        end

        # WHERE pattern for this level (as a UNION block)
        where_clause = []
        where_clause << "VALUES ?entity_id {\n      #{values_clause}\n    }"
        where_clause << "BIND(\"#{language}\" as ?filter_language) ."
        where_clause << "?entity_id a #{prefix}:#{entity_name} ;\n         ?property ?value0 ."
        where_clause << "FILTER(STRSTARTS(STR(?property), \"#{graph}\")) ."

        # Add language filter for level 0
        where_clause << "FILTER(\n      isIRI(?value0) ||\n      (isLiteral(?value0) && (\n        LANG(?value0) = ?filter_language || LANG(?value0) = \"\"\n      ))\n    )"

        # Add patterns for intermediate levels
        (1..level).each do |i|
          prev_var = "?value#{i-1}"
          curr_var = "?value#{i}"
          prop_var = "?property#{i-1}"

          where_clause << "FILTER(isIRI(#{prev_var})) ."
          where_clause << "#{prev_var} #{prop_var} #{curr_var} ."
          where_clause << "FILTER(STRSTARTS(STR(#{prop_var}), \"#{graph}\")) ."

          # Add language filter for this level
          where_clause << "FILTER(\n      isIRI(#{curr_var}) ||\n      (isLiteral(#{curr_var}) && (\n        LANG(#{curr_var}) = ?filter_language || LANG(#{curr_var}) = \"\"\n      ))\n    )"
        end

        # Add this level's WHERE clause to the UNION blocks
        where_unions << where_clause.join("\n    ")
      end

      # Combine everything into the final query
      query = <<~SPARQL
        #{prefix_block}

        CONSTRUCT {
          #{construct_patterns.join("\n  ")}
        }
        WHERE {
          #{where_unions.map { |union| "{\n    #{union}\n  }" }.join("\n  UNION\n  ")}
        }
      SPARQL

      query
    end

    def make_virtuoso_construct(entity_ids, entity_name, prefixes = {}, depth = 1, limit: 10_000)
      # --- SETUP ---
      ids = Array(entity_ids).flat_map { |id| id.to_s.split(/\s+/) }
      safe_values = ids.map { |id| "<#{id.gsub(/[<>]/, '')}>" }.join(" ")

      language = Graphiti.context[:object].language || Solis::Options.instance.get[:language] || 'en'
      main_graph = Solis::Options.instance.get[:graphs].find { |s| s['type'] == :main }
      graph_name = main_graph&.fetch('name', nil)
      graph_prefix = main_graph&.fetch('prefix', nil)

      # --- PREFIXES ---
      all_prefixes = prefixes.dup
      all_prefixes[graph_prefix] = graph_name if graph_prefix && !all_prefixes.key?(graph_prefix)
      all_prefixes['rdf'] = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#'
      all_prefixes['rdfs'] = 'http://www.w3.org/2000/01/rdf-schema#'

      prefix_block = all_prefixes.map { |k, v| "PREFIX #{k}: <#{v}>" }.join("\n")

      # --- SCHEMA AWARENESS ---
      # Generate the whitelist of predicates.
      # This acts as the "Filter", but uses the Index instead of string parsing.
      allowed_predicates = valid_predicates_list(graph_prefix)

      query = <<~SPARQL
        #{prefix_block}

        CONSTRUCT {
          ?s ?p ?o
        }
        WHERE {
          # 1. OPTIMIZATION: Transitive Subquery (The "Walker")
          #    First, efficiently gather the IDs of all nodes we need to display.
          {
            SELECT DISTINCT ?s
            WHERE {
              {
                # Include the roots themselves
                #VALUES ?s { #{safe_values} }
                BIND(#{safe_values} AS ?s)
              }
              UNION
              {
                VALUES ?root { #{safe_values} }
                ?root ?p_transitive ?s OPTION (
                  TRANSITIVE,
                  t_distinct,
                  t_min(1),
                  t_max(#{depth}),
                  t_no_cycles,
                  t_step('step_no') as ?step
                ) .

                # Ensure we only traverse along known schema properties 
                # (prevents traversing out of the "graph" via random links)
                VALUES ?p_transitive { #{allowed_predicates} }
                
                FILTER( isIRI(?s) )
              }
            }
            LIMIT #{limit}
          }

          # 2. DATA FETCHING
          #    Now, for every node found in the tree (?s), fetch its properties (?p) and values (?o).
          ?s ?p ?o .

          # 3. FILTERING
          #    Only return properties that are in our schema + rdf:type
          VALUES ?p { #{allowed_predicates} }

          # 4. LANGUAGE HANDLING
          #{language_filter('?o')}
        }
      SPARQL

      query
    end

    private

    def language_filter(var)
      <<~FILTER.strip
        FILTER(
          isIRI(#{var}) || 
          (isLiteral(#{var}) && (LANG(#{var}) = ?filter_language || LANG(#{var}) = ""))
        )
        BIND("#{Graphiti.context[:object].language || 'nl'}" as ?filter_language)
      FILTER
    end

    def valid_predicates_list(prefix)
      graph_name = Solis::Options.instance.get[:graphs].select{|s| s['type'].eql?(:main)}&.first['name']
      graph_prefix = Solis::Options.instance.get[:graphs].select{|s| s['type'].eql?(:main)}&.first['prefix']
      # Dynamically fetch schema properties from Solis
      paths = RDF::Graph.load(Solis::Options.instance.get[:shape])&.query([nil, RDF::Vocab::SHACL.path, nil]).map(&:object).uniq rescue nil
      return [] if paths.nil? || paths.empty?
      # Create list of prefixed properties (e.g., odis:label, odis:date)
      # IMPORTANT: Add 'rdf:type' explicitly here!
      list = paths.map do |uri|
        property = uri.value.gsub(graph_name, '')
        "#{graph_prefix}:#{property}"
      end
      list << "rdf:type"

      list.join(" ")
    end


    def resolve_concurrent(filename, id_name, entity, ids, from_cache = '1', offset = 0, limit = 10, depth = 1)
      raise 'Please supply one or more uuid\'s' if ids.nil? || ids.empty?

      key = Digest::SHA256.hexdigest("#{entity}-#{ids}-#{depth}")
      return cache[key] if cache.key?(key) && from_cache != '0'

      graph_name = Solis::Options.instance.get[:graphs].select { |s| s['type'].eql?(:main) }&.first['name']
      graph_prefix = Solis::Options.instance.get[:graphs].select { |s| s['type'].eql?(:main) }&.first['prefix']
      language = Graphiti.context[:object]&.language || Solis::Options.instance.get[:language] || 'en'

      model = $SOLIS.shape_as_model(entity)

      # Normalize IDs
      ids = ids.gsub(/[^a-zA-Z0-9\-\,]/, '')
      root_ids = ids.split(',').map { |m| "#{graph_name}#{entity.tableize}/#{m}" }

      # Use a thread pool for concurrent queries
      pool = Concurrent::FixedThreadPool.new(
        [Concurrent.processor_count, 5].min,
        max_queue: 100,
        fallback_policy: :caller_runs
      )

      begin
        result = query_with_depth_levels(
          root_ids: root_ids,
          entity: entity,
          graph_name: graph_name,
          graph_prefix: graph_prefix,
          language: language,
          depth: depth,
          pool: pool,
          batch_size: 25
        )

        cache.store(key, result, expires: 86400) unless result.empty?
        result
      ensure
        pool.shutdown
        pool.wait_for_termination(30)
      end
    rescue StandardError => e
      Solis::LOGGER.error("resolve_concurrent error: #{e.message}")
      Solis::LOGGER.error(e.backtrace.join("\n"))
      raise e
    end

    private

    def query_with_depth_levels(root_ids:, entity:, graph_name:, graph_prefix:, language:, depth:, pool:, batch_size: 25)
      # Store all entity data by IRI
      entity_store = Concurrent::Hash.new

      # Track visited IRIs to prevent circular references
      visited_iris = Concurrent::Set.new

      # Track IRI to entity type mapping
      iri_types = Concurrent::Hash.new

      # Initialize with root IDs
      current_level_iris = root_ids.dup
      root_ids.each { |iri| iri_types[iri] = entity }

      (0..depth).each do |level|
        break if current_level_iris.empty?

        Solis::LOGGER.debug("Processing depth level #{level} with #{current_level_iris.size} IRIs")

        # Filter out already visited IRIs
        new_iris = current_level_iris.reject { |iri| visited_iris.include?(iri) }
        break if new_iris.empty?

        # Mark as visited
        new_iris.each { |iri| visited_iris.add(iri) }

        # Split into batches for parallel processing
        batches = new_iris.each_slice(batch_size).to_a

        # Query batches concurrently
        futures = batches.map do |batch|
          Concurrent::Future.execute(executor: pool) do
            query_entities_batch(
              iris: batch,
              graph_name: graph_name,
              graph_prefix: graph_prefix,
              language: language
            )
          end
        end

        # Collect results and extract next level IRIs
        next_level_iris = Concurrent::Array.new

        futures.each do |future|
          begin
            batch_results = future.value!(60) # 60 second timeout per batch
            next if batch_results.nil? || batch_results.empty?

            batch_results.each do |iri, data|
              entity_store[iri] = data

              # Extract IRIs for next level
              extract_iris_from_entity(data, graph_name).each do |ref_iri, ref_type|
                unless visited_iris.include?(ref_iri)
                  next_level_iris << ref_iri
                  iri_types[ref_iri] = ref_type if ref_type
                end
              end
            end
          rescue Concurrent::TimeoutError => e
            Solis::LOGGER.warn("Timeout querying batch at level #{level}: #{e.message}")
          rescue StandardError => e
            Solis::LOGGER.error("Error querying batch at level #{level}: #{e.message}")
          end
        end

        current_level_iris = next_level_iris.to_a.uniq
      end

      # Reconstruct nested structure from flat entity store
      reconstruct_nested(root_ids, entity_store, graph_name)
    end

    def query_entities_batch(iris:, graph_name:, graph_prefix:, language:)
      return {} if iris.empty?

      values = iris.map { |iri| "<#{iri}>" }.join(" ")

      query = <<~SPARQL
        PREFIX #{graph_prefix}: <#{graph_name}>
        PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>

        SELECT ?s ?p ?o
        WHERE {
          VALUES ?s { #{values} }
          ?s ?p ?o .
          FILTER(
            STRSTARTS(STR(?p), "#{graph_name}") || 
            ?p = rdf:type
          )
          FILTER(
            isIRI(?o) ||
            (isLiteral(?o) && (LANG(?o) = "#{language}" || LANG(?o) = ""))
          )
        }
      SPARQL

      c = Solis::Store::Sparql::Client.new(
        Solis::Options.instance.get[:sparql_endpoint],
        graph_name: graph_name
      )

      results = c.query(query)

      group_results_by_subject(results, graph_name)
    rescue StandardError => e
      Solis::LOGGER.error("query_entities_batch error: #{e.message}")
      {}
    end

    def group_results_by_subject(results, graph_name)
      grouped = {}

      results.each do |solution|
        subject = solution[:s].to_s
        predicate = solution[:p].to_s
        object = solution[:o]

        grouped[subject] ||= { 'id' => subject.split('/').last }

        # Extract property name from predicate
        prop_name = predicate.gsub(graph_name, '').gsub('http://www.w3.org/1999/02/22-rdf-syntax-ns#', 'rdf:')

        # Handle the value
        value = if object.is_a?(RDF::URI)
                  object.to_s
                elsif object.respond_to?(:object)
                  object.object
                else
                  object.to_s
                end

        # Handle multiple values for same predicate
        if grouped[subject].key?(prop_name)
          existing = grouped[subject][prop_name]
          grouped[subject][prop_name] = existing.is_a?(Array) ? existing + [value] : [existing, value]
        else
          grouped[subject][prop_name] = value
        end
      end

      grouped
    end

    def extract_iris_from_entity(data, graph_name)
      iris = []

      data.each do |key, value|
        next if key.to_s.start_with?('@') || key == 'id'

        values = value.is_a?(Array) ? value : [value]
        values.each do |v|
          if v.is_a?(String) && v.start_with?(graph_name)
            # Try to determine entity type from IRI
            entity_type = v.split('/').last(2).first&.classify rescue nil
            iris << [v, entity_type]
          end
        end
      end

      iris
    end

    def reconstruct_nested(root_ids, entity_store, graph_name)
      # Build a lookup for quick access
      results = root_ids.map do |root_iri|
        reconstruct_entity(root_iri, entity_store, graph_name, Set.new)
      end.compact

      results.length == 1 ? results.first : results
    end

    def reconstruct_entity(iri, entity_store, graph_name, visited)
      return { 'id' => iri.split('/').last } if visited.include?(iri)

      data = entity_store[iri]
      return { 'id' => iri.split('/').last } unless data

      visited = visited + [iri] # Create new set to avoid mutation issues

      result = {}
      data.each do |key, value|
        if value.is_a?(Array)
          result[key] = value.map do |v|
            if v.is_a?(String) && v.start_with?(graph_name)
              reconstruct_entity(v, entity_store, graph_name, visited)
            else
              v
            end
          end
        elsif value.is_a?(String) && value.start_with?(graph_name)
          result[key] = reconstruct_entity(value, entity_store, graph_name, visited)
        else
          result[key] = value
        end
      end

      result
    end

  end

end
