require_relative 'base_transpiler'
module LuceneParser
  # Elasticsearch transpiler
  class ElasticsearchTranspiler < BaseTranspiler
    def visit_term(node)
      fields = resolve_field_list(node.field)
      queries = fields.map { |field| build_term_query(field, node) }

      return queries.first if queries.length == 1
      { bool: { should: queries } }
    end

    def visit_phrase(node)
      fields = resolve_field_list(node.field)
      queries = fields.map { |field| build_phrase_query(field, node) }

      return queries.first if queries.length == 1
      { bool: { should: queries } }
    end

    def visit_range(node)
      field = resolve_field(node.field)
      range_q = node.parsed_range

      query = { range: { field => {} } }

      if range_q.from
        query[:range][field][range_q.inclusive_from ? :gte : :gt] = range_q.from
      end

      if range_q.to
        query[:range][field][range_q.inclusive_to ? :lte : :lt] = range_q.to
      end

      query
    end

    def visit_and(node)
      { bool: { must: [visit(node.left), visit(node.right)] } }
    end

    def visit_or(node)
      { bool: { should: [visit(node.left), visit(node.right)] } }
    end

    def visit_not(node)
      { bool: { must_not: visit(node.child) } }
    end

    private

    def resolve_field_list(logical_field)
      resolved = resolve_field(logical_field)
      resolved.is_a?(Array) ? resolved : [resolved]
    end

    def build_term_query(field, node)
      if node.value.include?('*') || node.value.include?('?')
        query = { wildcard: { field => { value: node.value } } }
      elsif node.fuzzy
        query = { match: { field => { query: node.value, fuzziness: node.fuzzy } } }
      else
        query = { match: { field => node.value } }
      end

      query[query.keys.first][field] = { boost: node.boost } if node.boost
      query
    end

    def build_phrase_query(field, node)
      query = { match_phrase: { field => { query: node.phrase } } }
      query[:match_phrase][field][:boost] = node.boost if node.boost
      query
    end
  end
end