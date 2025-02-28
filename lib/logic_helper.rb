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

    def resolve(filename, id_name, entity, ids, from_cache = '1', depth = 1)
      raise 'Please supply one or more uuid\'s' if ids.nil? || ids.empty?

      result = {}

      key = Digest::SHA256.hexdigest("#{entity}-#{ids}")
      result = cache[key] if cache.key?(key)
      graph_name = Solis::Options.instance.get[:graph_name]
      graph_prefix = Solis::Options.instance.get[:graph_prefix]

      if result.nil? || result.empty? || (from_cache.eql?('0'))
        target_classes = target_class_for($SOLIS.shape_as_model(entity))
        ids = ids.gsub(/[^a-zA-Z0-9\-\,]/, '')
        if filename.empty?
          ids = ids.split(',').map { |m| "<#{Solis::Options.instance.get[:graph_name]}#{entity.tableize}/#{m}>" }
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
      prefix = Solis::Options.instance.get[:graph_prefix]
      graph = Solis::Options.instance.get[:graph_name]

      query = <<~SPARQL
    #{prefixes.map { |prefix, uri| "PREFIX #{prefix}: <#{uri}>" }.join("\n")}
    CONSTRUCT {
      ?entity_id  a #{prefix}:#{entity_name} ;
               ?property ?value0 .
  SPARQL

      depth.times do |i|
        query += "      ?value#{i} ?property#{i} ?value#{i+1} .\n"
      end

      query += <<~SPARQL
    }
    WHERE {
      VALUES ?entity_id {#{entity_id}}
      BIND("#{language}" as ?filter_language) .
      ?entity_id a #{prefix}:#{entity_name} ;
              ?property ?value0 .
      FILTER(STRSTARTS(STR(?property), "#{graph}")) .         
#      FILTER(DATATYPE(?value0) != rdf:langString || langMatches( lang(?value0), \"#{language}\" )).   
  SPARQL

      depth.times do |i|
        query += <<~SPARQL
      OPTIONAL {
        ?value#{i} ?property#{i} ?value#{i+1} .
        FILTER(isIRI(?value#{i})) .
        FILTER(STRSTARTS(STR(?property#{i}), "#{graph}")) .            
#        FILTER(DATATYPE(?value#{i+1}) != rdf:langString || langMatches( lang(?value#{i+1}), \"#{language}\" )).   
      }
    SPARQL
      end
      # FILTER (!BOUND(?value#{i}) || DATATYPE(?value#{i}) != rdf:langString || LANG(?value#{i}) = ?filter_language) .

      query += "}"
      query
    end
    def make_construct2(entity_id, entity_name, prefixes = {}, depth = 1)
      language = Graphiti.context[:object].language
      base_prefix = Solis::Options.instance.get[:graph_prefix]

      query = <<~SPARQL
        #{prefixes.map { |prefix, uri| "PREFIX #{prefix}: <#{uri}>" }.join("\n")}
        CONSTRUCT {
          ?entity ?property ?value0 .
      SPARQL

      depth.times do |i|
        query += "      ?value#{i} ?property#{i} ?value#{i + 1} .\n"
      end

      query += <<~SPARQL
        }
        WHERE {
          VALUES ?entity { #{entity_id} }
          BIND("#{language}" as ?filter_language).

          ?entity a #{base_prefix}:#{entity_name} ;
                  ?property ?value0 .
      SPARQL

      depth.times do |i|
        query += <<~SPARQL
          OPTIONAL {
            ?value#{i} ?property#{i} ?value#{i + 1} .
            FILTER(isIRI(?value#{i}))
          }
        SPARQL
      end

      query += "}"

      puts query
      query
    end
  end
end
