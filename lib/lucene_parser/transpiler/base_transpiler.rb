module LuceneParser
  # Base transpiler
  class BaseTranspiler
    attr_reader :field_mappings

    def initialize(field_mappings = nil)
      @field_mappings = field_mappings || FieldMappings.new({}, fallback_strategy: :pass_through)
    end

    def visit(node)
      case node
      when TermNode then visit_term(node)
      when PhraseNode then visit_phrase(node)
      when RangeNode then visit_range(node)
      when AndNode then visit_and(node)
      when OrNode then visit_or(node)
      when NotNode then visit_not(node)
      else raise "Unknown node type: #{node.class}"
      end
    end

    def resolve_field(logical_field)
      @field_mappings.resolve(logical_field)
    end

    def visit_term(node)
      raise NotImplementedError
    end

    def visit_phrase(node)
      raise NotImplementedError
    end

    def visit_range(node)
      raise NotImplementedError
    end

    def visit_and(node)
      raise NotImplementedError
    end

    def visit_or(node)
      raise NotImplementedError
    end

    def visit_not(node)
      raise NotImplementedError
    end
  end
end