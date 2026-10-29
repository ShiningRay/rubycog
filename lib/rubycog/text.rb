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
  # segments instead of literal markers. Every line comes back as a Row, so a
  # single line can mix styles.
  module Markdown
    module_function

    FENCE = '```'
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

    # Turns text into rows, one per display line.
    def lines(text, width)
      rows = []
      fenced = false
      text.to_s.split("\n", -1).each do |line|
        if line.strip.start_with?(FENCE)
          fenced = !fenced
          next
        end
        rows.concat(fenced ? code_lines(line, width) : plain_lines(line, width))
      end
      rows
    end

    # Every line marked as code: used for tool calls, which are code by nature.
    def code_lines(text, width)
      text.to_s.split("\n", -1).flat_map { |line| code_rows(line, width) }
    end

    def plain_lines(line, width)
      heading = line.match?(HEADING)
      fill(inline_chars(heading ? line.sub(HEADING, '') : line, heading ? :heading : nil), width)
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
end
