module Logic
  module Helper
    private
    def api_error(status, source, title="Unknown error", detail="")
      {"errors": [{
                    "status": status,
                    "source": {"pointer":  source},
                    "title": title,
                    "detail": detail
                  }]}
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

    def resolve(filename, id_name, entity, ids, from_cache = '1')
      raise 'Please supply one or more uuid\'s' if ids.nil? || ids.empty?

      result = {}

      key = Digest::SHA256.hexdigest("#{entity}-#{ids}")
      result = cache[key] if cache.key?(key)

      if result.nil? || result.empty? || (from_cache.eql?('0'))
        target_classes = target_class_for($SOLIS.shape_as_model(entity))
        f = File.read(filename)
         ids = ids.gsub(/[^a-zA-Z0-9\-\,]/,'')
        ids = ids.split(',').map { |m| target_classes.map {|target_class| "<#{target_class}/#{m}>" }}
        #ids = ids.split(',').map { |m| "<#{Solis::Options.instance.get[:graph_name]}#{entity.tableize}/#{m}>" }
        ids = [ids] unless ids.is_a?(Array)
        ids = ids.join(" ")
        language = Graphiti.context[:object].language
        q = f.gsub(/{ ?{ ?VALUES ?} ?}/, "VALUES ?#{id_name} { #{ids} }").gsub(/{ ?{ ?LANGUAGE ?} ?}/, "bind(\"#{language}\" as ?filter_language).")

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
  end
end
