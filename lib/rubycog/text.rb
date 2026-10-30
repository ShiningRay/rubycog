# frozen_string_literal: true

require 'io/console'

module Rubycog
  module Text
    module_function

    def width(text)
      text.each_char.sum do |char|
        next 0 if char.ord < 32
        next 2 if wide?(char)

        1
      end
    end

    def wide?(char)
      codepoint = char.ord
      codepoint.between?(0x1100, 0x115f) ||
        codepoint.between?(0x2e80, 0xa4cf) ||
        codepoint.between?(0xac00, 0xd7a3) ||
        codepoint.between?(0xf900, 0xfaff) ||
        codepoint.between?(0xfe30, 0xfe4f) ||
        codepoint.between?(0xff00, 0xff60) ||
        codepoint.between?(0xffe0, 0xffe6) ||
        codepoint.between?(0x1f300, 0x1faff) ||
        codepoint.between?(0x20000, 0x3fffd)
    end

    def slice(text, start, length)
      return '' if length <= 0

      skipped = 0
      result = +''
      used = 0
      text.each_char do |char|
        char_width = width(char)
        if skipped + char_width <= start
          skipped += char_width
          next
        end
        break if used + char_width > length

        result << char
        used += char_width
      end
      result
    end

    def wrap(text, width)
      return [''] if width < 1

      text.to_s.split("\n", -1).flat_map do |line|
        rows = [+'']
        remaining = width
        line.scan(/\S+\s*|\s+/) do |word|
          word.each_char do |char|
            if width(char) > remaining
              rows << +'' unless rows.last.empty?
              remaining = width
            end
            rows.last << char
            remaining -= width(char)
          end
        end
        rows
      end
    end
  end

  # Markdown for the transcript. Fenced code blocks are marked as code (so the
  # caller can colour and indent them), headings lose their hashes and are
  # marked for emphasis, and inline `code`, **bold** and *italic* become styled
  # segments instead of literal markers. A fence tagged ruby (or rb) is
  # tokenised like eval code; every other fence stays plain code. Every line
  # comes back as a Row, so a single line can mix styles.
  module Markdown
    module_function

    FENCE = '```'
    # Fence languages RubyHighlight understands. Anything else (json, sh, an
    # untagged fence) keeps the plain code colour rather than being guessed as
    # Ruby, where "if"/"then"/"end" would light up in the wrong language.
    RUBY_FENCES = %w[ruby rb].freeze
    HEADING = /\A\#{1,6}\s+/
    # Inline spans, tried left to right: `code`, **bold**, *italic*. A marker
    # only counts when non-space text follows and precedes it, so "2 * 3 * 4"
    # stays literal. Underscore emphasis is deliberately unsupported: it would
    # mangle snake_case identifiers in a coding transcript.
    INLINE = /`([^`\n]+)`|\*\*(?=\S)(.+?)(?<=\S)\*\*|\*(?=\S)(.+?)(?<=\S)\*/

    # One wrapped display row: [text, style] segments that together fit the
    # requested width. Styles are nil for prose, otherwise :code, :heading,
    # :bold, :italic or :inline_code; the UI maps them to colours and
    # attributes.
    class Row
      attr_reader :segments

      def initialize(segments = [])
        @segments = segments
        @width = segments.sum { |text, _style| Text.width(text) }
      end

      # Appends text in one style, merging into the previous segment when the
      # style matches so a row stays a short list of runs.
      def concat(text, style = nil)
        return self if text.nil? || text.empty?

        last = @segments.last
        if last && last[1] == style
          last[0] << text
        else
          @segments << [+text, style]
        end
        @width += Text.width(text)
        self
      end

      # Returns a copy with `prefix` in front, used for the transcript indent.
      def indented(prefix, style = nil)
        Row.new([[+prefix, style], *@segments])
      end

      # Plain text of the row without styling: used by tests and by search.
      def text = @segments.map(&:first).join

      def width = @width
      def empty? = @width.zero?
    end

    # Turns text into rows, one per display line. Rows inside a ruby fence carry
    # token styles; rows inside any other fence carry the plain code style.
    def lines(text, width)
      rows = []
      fenced = false
      ruby = false
      text.to_s.split("\n", -1).each do |line|
        if line.strip.start_with?(FENCE)
          fenced = !fenced
          ruby = fenced && ruby_fence?(line.strip)
          next
        end
        rows.concat(fenced ? fenced_lines(line, width, ruby) : plain_lines(line, width))
      end
      rows
    end

    # True when a fence marker names a language RubyHighlight can colour, e.g.
    # "```ruby" or "```rb title=x"; an untagged "```" is not one.
    def ruby_fence?(marker)
      RUBY_FENCES.include?(marker[FENCE.length..].to_s.split.first.to_s.downcase)
    end

    # One line inside a fence: Ruby tokens when the fence named Ruby, plain code
    # otherwise. Both indent the same way, so widths and wraps do not move.
    def fenced_lines(line, width, ruby)
      ruby ? ruby_rows(line, width) : code_rows(line, width)
    end

    # Every line marked as code: used for tool calls, which are code by nature.
    def code_lines(text, width)
      text.to_s.split("\n", -1).flat_map { |line| code_rows(line, width) }
    end

    def plain_lines(line, width)
      heading = line.match?(HEADING)
      fill(inline_chars(heading ? line.sub(HEADING, '') : line, heading ? :heading : nil), width)
    end

    # Like code_lines, but Ruby tokens keep their own style so eval code reads
    # like source. Row widths, indent and line breaks are identical to
    # code_lines, so highlighting never moves a wrap or a search row.
    def ruby_lines(text, width)
      text.to_s.split("\n", -1).flat_map { |line| ruby_rows(line, width) }
    end

    def ruby_rows(line, width)
      inner = [width - 2, 1].max
      fill(RubyHighlight.chars(line), inner).map { |row| row.indented('  ', :code) }
    end

    # Two extra spaces keep code visibly apart from prose, so wrap inside them.
    def code_rows(line, width)
      inner = [width - 2, 1].max
      fill(line.each_char.map { |char| [char, :code] }, inner).map { |row| row.indented('  ', :code) }
    end

    # Splits a line into [char, style] pairs with the inline markers removed.
    def inline_chars(line, base = nil)
      chars = []
      source = line.to_s
      pos = 0
      while (match = INLINE.match(source, pos))
        add_chars(chars, source[pos...match.begin(0)], base)
        style, content = inline_span(match)
        add_chars(chars, content, style)
        pos = match.end(0)
      end
      add_chars(chars, source[pos..], base)
      chars
    end

    # Which inline style a match carries, and the text inside its markers.
    def inline_span(match)
      return [:inline_code, match[1]] if match[1]
      return [:bold, match[2]] if match[2]

      [:italic, match[3]]
    end

    def add_chars(chars, text, style)
      text.to_s.each_char { |char| chars << [char, style] }
    end

    # Wraps [char, style] pairs into rows, breaking exactly where Text.wrap
    # does so styling never moves the line breaks.
    def fill(chars, width)
      return [Row.new] if width < 1

      rows = [Row.new]
      chars.each do |char, style|
        rows << Row.new if !rows.last.empty? && Text.width(char) > width - rows.last.width
        rows.last.concat(char, style)
      end
      rows
    end
  end

  # Line-oriented Ruby highlighter for eval code. It is a display aid, not a
  # parser: each line is tokenised on its own and anything unrecognised stays
  # plain, so a half-typed or multi-line construct costs colour, never text.
  #
  # Alternatives are tried left to right at the earliest position, which is what
  # keeps the rules honest: a string swallows the "#" and ":sym" inside it, "::"
  # is refused as a symbol so Foo::Bar keeps its constant, and a comment runs to
  # the end of the line.
  module RubyHighlight
    module_function

    KEYWORDS = %w[__FILE__ __LINE__ __method__ alias and begin break case class def
                  defined? do else elsif end ensure false for if in module next nil
                  not or redo rescue retry return self super then true undef unless
                  until when while yield].freeze
    # Built once here so the token pattern below stays readable.
    KEYWORD = /\b(?:#{KEYWORDS.map { |word| Regexp.escape(word) }.join('|')})\b/

    # One alternative per token class. The "x" flag and escaped brackets keep
    # the brackets of a %w[] literal from ending the pattern.
    TOKEN = %r~
        (?<comment>\#[^\n]*)
      | (?<string>"(?:[^"\\]|\\.)*"?|'(?:[^'\\]|\\.)*'?)
      | (?<method>(?<=\bdef\s)[a-z_]\w*[?!=]?)
      | (?<symbol>(?<!:):[A-Za-z_]\w*[?!=]?)
      | (?<number>\b\d[\d_]*(?:\.\d[\d_]*)?\b)
      | (?<constant>\b[A-Z]\w*[?!]?)
      | (?<keyword>#{KEYWORD.source})
    ~x

    # Group name to the style the UI knows. Every group in TOKEN is named here,
    # so a new token class cannot silently arrive without a colour.
    STYLE_FOR = {
      'comment' => :comment, 'string' => :string, 'method' => :method,
      'symbol' => :symbol, 'number' => :number, 'constant' => :constant,
      'keyword' => :keyword
    }.freeze

    # [char, style] pairs for one line, in order, with no character dropped.
    def chars(line)
      out = []
      source = line.to_s
      pos = 0
      while (match = TOKEN.match(source, pos))
        push(out, source[pos...match.begin(0)], nil)
        push(out, match[0], STYLE_FOR[token_name(match)])
        pos = match.end(0)
      end
      push(out, source[pos..], nil)
      out
    end

    # The named group that matched; every alternative is named, so this only
    # returns nil for a pattern change that forgets to name one.
    def token_name(match)
      match.names.find { |name| match[name] }
    end

    def push(out, text, style)
      text.to_s.each_char { |char| out << [char, style] }
    end
  end
end
