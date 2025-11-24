require_relative 'base_transpiler'
module LuceneParser
  # SRU/CQL transpiler
  class SRUTranspiler < BaseTranspiler
    def visit_term(node)
      field = resolve_field(node.field)
      "#{field} any #{node.value}"
    end

    def visit_phrase(node)
      field = resolve_field(node.field)
      "#{field} exact \"#{node.phrase}\""
    end

    def visit_range(node)
      field = resolve_field(node.field)
      range_q = node.parsed_range

      from = range_q.from || '*'
      to = range_q.to || '*'
      "#{field} within #{from} #{to}"
    end

    def visit_and(node)
      "#{visit(node.left)} and #{visit(node.right)}"
    end

    def visit_or(node)
      "#{visit(node.left)} or #{visit(node.right)}"
    end

    def visit_not(node)
      "not (#{visit(node.child)})"
    end
  end
end
