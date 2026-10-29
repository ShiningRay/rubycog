# frozen_string_literal: true

require_relative 'test_helper'

class MarkdownTest < Minitest::Test
  def test_marks_fenced_lines_as_code_and_drops_the_fences
    rows = Rubycog::Markdown.lines("before\n```ruby\nx = 1\n```\nafter", 40)

    assert_equal [['before', nil], ['  x = 1', :code], ['after', nil]], rows
  end

  def test_strips_heading_hashes_and_marks_the_line
    assert_equal [['Plan', :heading]], Rubycog::Markdown.lines('## Plan', 40)
  end

  def test_leaves_inline_syntax_as_typed
    assert_equal [['a **bold** and `code`', nil]],
                 Rubycog::Markdown.lines('a **bold** and `code`', 40)
  end

  def test_wraps_code_inside_its_indent
    rows = Rubycog::Markdown.lines("```\n#{'x' * 30}\n```", 10)

    assert_equal 4, rows.length
    assert(rows.all? { |line, style| style == :code && line.start_with?('  ') && Rubycog::Text.width(line) <= 10 })
  end

  def test_code_lines_styles_every_line_without_fence_detection
    rows = Rubycog::Markdown.code_lines("a = 1\n```\n# not a heading", 40)

    assert_equal [['  a = 1', :code], ['  ```', :code], ['  # not a heading', :code]], rows
  end

  def test_renders_no_rows_for_missing_text
    assert_empty Rubycog::Markdown.lines(nil, 20)
  end
end
