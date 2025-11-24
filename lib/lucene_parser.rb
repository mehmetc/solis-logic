require_relative './lucene_parser/query_sanitizer'
require_relative './lucene_parser/transpiler/lucene_transpiler'

module LuceneParser
  # Token types
  module TokenType
    FIELD = :field
    TERM = :term
    PHRASE = :phrase
    AND = :and
    OR = :or
    NOT = :not
    LPAREN = :lparen
    RPAREN = :rparen
    RANGE = :range
    BOOST = :boost
    WILDCARD = :wildcard
    FUZZY = :fuzzy
    EOF = :eof
  end

  # Tokenizer for Lucene syntax
  class Tokenizer
    def initialize(input)
      @input = input
      @pos = 0
      @tokens = []
    end

    def tokenize
      while @pos < @input.length
        case @input[@pos]
        when /\s/
          @pos += 1
        when '('
          @tokens << Token.new(TokenType::LPAREN, '(', @pos)
          @pos += 1
        when ')'
          @tokens << Token.new(TokenType::RPAREN, ')', @pos)
          @pos += 1
        when '"'
          read_phrase
        when '['
          read_range
        when /[A-Za-z_]/
          read_field_or_keyword
        else
          read_term
        end
      end
      @tokens << Token.new(TokenType::EOF, nil, @pos)
      @tokens
    end

    private

    def read_phrase
      start = @pos
      @pos += 1
      phrase = ""
      while @pos < @input.length && @input[@pos] != '"'
        phrase += @input[@pos]
        @pos += 1
      end
      @pos += 1 # skip closing quote
      @tokens << Token.new(TokenType::PHRASE, phrase, start)
    end

    def read_range
      start = @pos
      @pos += 1
      range_str = ""
      while @pos < @input.length && @input[@pos] != ']'
        range_str += @input[@pos]
        @pos += 1
      end
      @pos += 1 # skip ]
      @tokens << Token.new(TokenType::RANGE, range_str, start)
    end

    def read_field_or_keyword
      start = @pos
      word = ""
      while @pos < @input.length && @input[@pos] =~ /[A-Za-z0-9_]/
        word += @input[@pos]
        @pos += 1
      end

      # Skip optional spaces before checking for colon
      pos_after_word = @pos
      while @pos < @input.length && @input[@pos] =~ /\s/
        @pos += 1
      end

      if @pos < @input.length && @input[@pos] == ':'
        @pos += 1
        @tokens << Token.new(TokenType::FIELD, word, start)
      elsif word == 'AND'
        @pos = pos_after_word # Reset if not a field
        @tokens << Token.new(TokenType::AND, word, start)
      elsif word == 'OR'
        @pos = pos_after_word # Reset if not a field
        @tokens << Token.new(TokenType::OR, word, start)
      elsif word == 'NOT'
        @pos = pos_after_word # Reset if not a field
        @tokens << Token.new(TokenType::NOT, word, start)
      else
        @pos = start # Reset to start of word
        read_term
      end
    end

    def read_term
      start = @pos
      term = ""
      while @pos < @input.length && @input[@pos] !~ /[\s()\[\]"]/
        term += @input[@pos]
        @pos += 1
      end

      # Check for boost, fuzzy, wildcards
      case term
      when /^(.+?)\^(\d+\.?\d*)$/
        Regexp.last_match
        @tokens << Token.new(TokenType::TERM, Regexp.last_match(1), start)
        @tokens << Token.new(TokenType::BOOST, Regexp.last_match(2), start)
      when /^(.+?)~(\d?)$/
        Regexp.last_match
        @tokens << Token.new(TokenType::TERM, Regexp.last_match(1), start)
        @tokens << Token.new(TokenType::FUZZY, Regexp.last_match(2), start)
      when /[*?]/
        @tokens << Token.new(TokenType::WILDCARD, term, start)
      else
        @tokens << Token.new(TokenType::TERM, term, start)
      end
    end
  end

  Token = Struct.new(:type, :value, :position)

  # AST Node classes
  class Node; end

  class TermNode < Node
    attr_reader :field, :value, :boost, :fuzzy

    def initialize(field: nil, value:, boost: nil, fuzzy: nil)
      @field = field
      @value = value
      @boost = boost
      @fuzzy = fuzzy
    end
  end

  class PhraseNode < Node
    attr_reader :field, :phrase, :boost

    def initialize(field: nil, phrase:, boost: nil)
      @field = field
      @phrase = phrase
      @boost = boost
    end
  end

  # Parse Lucene range syntax: [from TO to], {from TO to}, [from TO *], etc
  class RangeQuery
    attr_reader :from, :to, :inclusive_from, :inclusive_to

    def initialize(range_str)
      # Handle both [ ] (inclusive) and { } (exclusive)
      if range_str.start_with?('{')
        @inclusive_from = false
        range_str = range_str[1..]
      else
        @inclusive_from = true
        range_str = range_str[1..] if range_str.start_with?('[')
      end

      if range_str.end_with?('}')
        @inclusive_to = false
        range_str = range_str[0..-2]
      else
        @inclusive_to = true
        range_str = range_str[0..-2] if range_str.end_with?(']')
      end

      parts = range_str.match(/(.+?)\s+TO\s+(.+?)/)
      raise "Invalid range format: #{range_str}" unless parts

      @from = parts[1].strip
      @to = parts[2].strip
      @from = nil if @from == '*'
      @to = nil if @to == '*'
    end
  end

  class RangeNode < Node
    attr_reader :field, :range_str, :parsed_range

    def initialize(field:, range_str:)
      @field = field
      @range_str = range_str
      @parsed_range = RangeQuery.new(range_str)
    end
  end

  class AndNode < Node
    attr_reader :left, :right

    def initialize(left, right)
      @left = left
      @right = right
    end
  end

  class OrNode < Node
    attr_reader :left, :right

    def initialize(left, right)
      @left = left
      @right = right
    end
  end

  class NotNode < Node
    attr_reader :child

    def initialize(child)
      @child = child
    end
  end

  # Parser
  class Parser
    def initialize(tokens)
      @tokens = tokens
      @pos = 0
    end

    def parse
      expr = parse_or_expr
      expect(TokenType::EOF)
      expr
    end

    private

    def parse_or_expr
      left = parse_and_expr
      while peek && peek.type == TokenType::OR
        advance # consume OR
        right = parse_and_expr
        left = OrNode.new(left, right)
      end
      left
    end

    def parse_and_expr
      left = parse_not_expr

      # Explicit AND operators or implicit AND (adjacent terms)
      while peek && (peek.type == TokenType::AND ||
        (peek.type != TokenType::OR &&
          peek.type != TokenType::RPAREN &&
          peek.type != TokenType::EOF))
        advance if peek.type == TokenType::AND # consume explicit AND
        right = parse_not_expr
        left = AndNode.new(left, right)
      end
      left
    end

    def parse_not_expr
      if peek && peek.type == TokenType::NOT
        advance
        NotNode.new(parse_not_expr)
      else
        parse_primary
      end
    end

    def parse_primary
      return parse_grouped if peek.type == TokenType::LPAREN

      field = nil
      field = advance.value if peek.type == TokenType::FIELD

      case peek.type
      when TokenType::PHRASE
        phrase = advance.value
        boost = parse_boost
        PhraseNode.new(field: field, phrase: phrase, boost: boost)
      when TokenType::RANGE
        range_str = advance.value
        RangeNode.new(field: field, range_str: range_str)
      when TokenType::TERM, TokenType::WILDCARD
        term = advance.value
        boost = parse_boost
        fuzzy = parse_fuzzy
        TermNode.new(field: field, value: term, boost: boost, fuzzy: fuzzy)
      else
        raise "Unexpected token: #{peek.inspect}"
      end
    end

    def parse_grouped
      advance # consume (
      expr = parse_or_expr
      expect(TokenType::RPAREN)
      expr
    end

    def parse_boost
      return nil unless peek && peek.type == TokenType::BOOST
      advance.value.to_f
    end

    def parse_fuzzy
      return nil unless peek && peek.type == TokenType::FUZZY
      fuzzy_val = advance.value
      fuzzy_val.empty? ? 1 : fuzzy_val.to_i
    end

    def peek
      @tokens[@pos]
    end

    def advance
      token = @tokens[@pos]
      @pos += 1
      token
    end

    def expect(type)
      raise "Expected #{type}, got #{peek.inspect}" if peek.type != type
      advance
    end
  end

  # Field mappings configuration
  class FieldMappings
    attr_reader :mappings, :default_index

    # fallback_strategy: :error, :default, :pass_through
    # default_index: the logical index name to use when no field is specified (default: 'any')
    def initialize(mappings = {}, fallback_strategy: :error, default_field: nil, default_index: 'any')
      @mappings = mappings
      @fallback_strategy = fallback_strategy
      @default_field = default_field
      @default_index = default_index
    end

    def resolve(logical_field)
      # Use default_index if no field is specified
      field_to_resolve = logical_field || @default_index

      if @mappings.key?(field_to_resolve)
        @mappings[field_to_resolve]
      else
        handle_unmapped(field_to_resolve)
      end
    end

    private

    def handle_unmapped(field)
      case @fallback_strategy
      when :error
        raise "Field '#{field}' not found in mappings"
      when :default
        @default_field || field
      when :pass_through
        field
      end
    end
  end
end