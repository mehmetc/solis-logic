module LuceneParser
  # Query sanitizer for cleaning and normalizing user input
  class QuerySanitizer
    # Remove/normalize problematic characters while preserving Lucene syntax
    def self.sanitize(query, options = {})
      return '' if query.nil? || query.empty?

      # Default options
      normalize_whitespace = options.fetch(:normalize_whitespace, true)
      escape_special_chars = options.fetch(:escape_special_chars, false)
      preserve_operators = options.fetch(:preserve_operators, true)
      remove_invalid_quotes = options.fetch(:remove_invalid_quotes, true)

      result = query.dup

      # Normalize whitespace: collapse multiple spaces, tabs to single space
      if normalize_whitespace
        result = result.gsub(/\s+/, ' ').strip
      end

      # Remove control characters (except newlines which become spaces)
      result = result.gsub(/[\x00-\x08\x0B-\x0C\x0E-\x1F]/, ' ')

      # Handle unmatched quotes
      if remove_invalid_quotes
        result = fix_unmatched_quotes(result)
      end

      # Escape special characters if requested (but preserve field colons and operators)
      if escape_special_chars
        result = escape_special_chars(result, preserve_operators)
      end

      result.strip
    end

    private

    def self.fix_unmatched_quotes(query)
      double_quotes = query.count('"')
      single_quotes = query.count("'")

      # Remove trailing unmatched quote
      if double_quotes.odd?
        query = query.reverse.sub('"', '', &:to_s).reverse
      end

      if single_quotes.odd?
        query = query.reverse.sub("'", '', &:to_s).reverse
      end

      query
    end

    def self.escape_special_chars(query, preserve_operators)
      # Lucene special chars: + - && || ! ( ) { } [ ] ^ " ~ * ? : \
      # Preserve: : (field separator), [ ] TO (ranges), " (phrases)
      # Optionally preserve: AND OR NOT

      special_chars = /[+\-&|!(){}\^~*?\\]/

      result = query.gsub(special_chars) { |char| "\\#{char}" }

      # Unescape if operators should be preserved
      if preserve_operators
        result = result.gsub(/\\(AND|OR|NOT)\b/, '\1')
      end

      result
    end
  end
end