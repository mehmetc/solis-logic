require_relative 'base_transpiler'

module LuceneParser
  # Lucene transpiler - generates Lucene query syntax
  class LuceneTranspiler < BaseTranspiler
    def visit_term(node)
      field = resolve_field(node.field)
      field_prefix = field ? "#{field}:" : ""

      term = node.value
      term = "#{term}~#{node.fuzzy}" if node.fuzzy
      term = "#{term}^#{node.boost}" if node.boost
      "#{field_prefix}#{term}"
    end

    def visit_phrase(node)
      field = resolve_field(node.field)
      field_prefix = field ? "#{field}:" : ""

      phrase = "\"#{node.phrase}\""
      phrase = "#{phrase}^#{node.boost}" if node.boost
      "#{field_prefix}#{phrase}"
    end

    def visit_range(node)
      field = resolve_field(node.field)
      range_q = node.parsed_range

      from = range_q.from || '*'
      to = range_q.to || '*'

      bracket_open = range_q.inclusive_from ? '[' : '{'
      bracket_close = range_q.inclusive_to ? ']' : '}'

      "#{field}:#{bracket_open}#{from} TO #{to}#{bracket_close}"
    end

    def visit_and(node)
      left = visit(node.left)
      right = visit(node.right)
      needs_parens_left = node.left.is_a?(OrNode)
      needs_parens_right = node.right.is_a?(OrNode)

      left = "(#{left})" if needs_parens_left
      right = "(#{right})" if needs_parens_right

      "#{left} AND #{right}"
    end

    def visit_or(node)
      "#{visit(node.left)} OR #{visit(node.right)}"
    end

    def visit_not(node)
      child = visit(node.child)
      child = "(#{child})" if node.child.is_a?(OrNode) || node.child.is_a?(AndNode)
      "NOT #{child}"
    end
  end
end