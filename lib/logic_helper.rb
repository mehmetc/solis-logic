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

    def resolve(filename, id_name, entity, ids, from_cache = '1', offset = 0, limit = 10, depth = 1)
      raise 'Please supply one or more uuid\'s' if ids.nil? || ids.empty?

      result = {}

      key = Digest::SHA256.hexdigest("#{entity}-#{ids}")
      result = cache[key] if cache.key?(key)
      graph_name = Solis::Options.instance.get[:graphs].select{|s| s['type'].eql?(:main)}&.first['name']
      graph_prefix = Solis::Options.instance.get[:graphs].select{|s| s['type'].eql?(:main)}&.first['prefix']

      if result.nil? || result.empty? || (from_cache.eql?('0'))
        target_classes = target_class_for($SOLIS.shape_as_model(entity))
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
        f = make_construct(ids,entity, {"#{graph_prefix}" => graph_name, "rdf" => "http://www.w3.org/1999/02/22-rdf-syntax-ns#"}, depth) if f.nil?

        q = f.gsub(/{ ?{ ?VALUES ?} ?}/, "VALUES ?#{id_name} { #{ids} }")
             .gsub(/{ ?{ ?LANGUAGE ?} ?}/, "bind(\"#{language}\" as ?filter_language).")
             .sub(/{ ?{ ?ENTITY ?} ?}/, entity)
             .sub(/{ ?{ ?GRAPH ?} ?}/, graph_name)
             .sub(/{ ?{ ?OFFSET ?} ?}/, offset.to_i.to_s)
             .sub(/{ ?{ ?LIMIT ?} ?}/, limit.to_i.to_s)
        puts q
        result = Solis::Query.run(entity, q)
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

    def make_construct(entity_id, entity_name, prefixes = {}, depth = 1)
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
  end
end
