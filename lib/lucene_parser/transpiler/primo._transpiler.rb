require_relative 'base_transpiler'
module LuceneParser
  # Primo transpiler (simplified - maps to Primo's query language)
  class PrimoTranspiler < BaseTranspiler
    def visit_term(node)
      field = resolve_field(node.field)
      "#{field},exact,#{node.value}"
    end

    def visit_phrase(node)
      field = resolve_field(node.field)
      "#{field},exact,\"#{node.phrase}\""
    end

    def visit_range(node)
      field = resolve_field(node.field)
      range_q = node.parsed_range

      from = range_q.from || '*'
      to = range_q.to || '*'
      "#{field},range,#{from}-#{to}"
    end

    def visit_and(node)
      "#{visit(node.left)};#{visit(node.right)}"
    end

    def visit_or(node)
      "#{visit(node.left)},#{visit(node.right)}"
    end

    def visit_not(node)
      "#{visit(node.child)},not"
    end
  end
end