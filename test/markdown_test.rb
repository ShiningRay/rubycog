# frozen_string_literal: true

require_relative 'test_helper'

class MarkdownTest < Minitest::Test
  def test_marks_fenced_lines_as_code_and_drops_the_fences
    rows = Rubycog::Markdown.lines("before\n```ruby\nx = 1\n```\nafter", 40)

    assert_equal ['before', '  x = 1', 'after'], rows.map(&:text)
    assert_equal [[:code, '  '], [:code, 'x = 1']], rows[1].segments.map(&:reverse)
  end

  def test_strips_heading_hashes_and_marks_the_line
    rows = Rubycog::Markdown.lines('## Plan', 40)

    assert_equal ['Plan'], rows.map(&:text)
    assert_equal [[:heading, 'Plan']], rows.first.segments.map(&:reverse)
  end

  def test_splits_inline_bold_code_and_italic_into_styled_segments
    rows = Rubycog::Markdown.lines('a **bold** and `code` plus *soft*', 60)

    assert_equal [['a ', nil], ['bold', :bold], [' and ', nil], ['code', :inline_code],
                  [' plus ', nil], ['soft', :italic]], rows.first.segments
    refute_includes rows.first.text, '*'
    refute_includes rows.first.text, '`'
  end

  def test_leaves_lone_asterisks_and_snake_case_alone
    text = 'call read_source_value with 2 * 3 * 4 and ** unmatched'
    rows = Rubycog::Markdown.lines(text, 80)

    assert_equal text, rows.first.text
    assert_equal [nil], rows.first.segments.map(&:last).uniq
  end

  def test_wraps_code_inside_its_indent
    rows = Rubycog::Markdown.lines("```\n#{'x' * 30}\n```", 10)

    assert_equal 4, rows.length
    assert(rows.all? { |row| row.text.start_with?('  ') && Rubycog::Text.width(row.text) <= 10 })
  end

  def test_code_lines_styles_every_line_without_fence_detection
    rows = Rubycog::Markdown.code_lines("a = 1\n```\n# not a heading", 40)

    assert_equal ['  a = 1', '  ```', '  # not a heading'], rows.map(&:text)
    assert_equal [[:code], [:code], [:code]], rows.map { |row| row.segments.map(&:last).uniq }
  end

  def test_inline_markers_do_not_change_where_lines_break
    plain = Rubycog::Markdown.lines('alpha beta gamma delta', 12).map(&:text)
    styled = Rubycog::Markdown.lines('**alpha** beta `gamma` delta', 12).map(&:text)

    assert_equal plain, styled
  end

  def test_renders_no_rows_for_missing_text
    assert_empty Rubycog::Markdown.lines(nil, 20)
  end
end
