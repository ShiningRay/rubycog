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

  # Block-level Markdown for the transcript: fenced code blocks are marked as
  # code (so the caller can color and indent them), headings lose their hashes
  # and are marked for emphasis, and everything else is shown as typed. Inline
  # syntax is deliberately not parsed.
  module Markdown
    module_function

    FENCE = '```'
    HEADING = /\A\#{1,6}\s+/

    # Turns text into [line, style] pairs, style being :code, :heading, or nil.
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
      return Text.wrap(line, width).map { |row| [row, nil] } unless line.match?(HEADING)

      Text.wrap(line.sub(HEADING, ''), width).map { |row| [row, :heading] }
    end

    # Two extra spaces keep code visibly apart from prose, so wrap inside them.
    def code_rows(line, width)
      Text.wrap(line, [width - 2, 1].max).map { |row| ["  #{row}", :code] }
    end
  end
end
