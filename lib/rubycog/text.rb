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
end
