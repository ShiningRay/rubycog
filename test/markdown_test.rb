# frozen_string_literal: true

require_relative 'test_helper'

class MarkdownTest < Minitest::Test
  def test_marks_fenced_lines_as_code_and_drops_the_fences
    rows = Rubycog::Markdown.lines("before\n```\nx = 1\n```\nafter", 40)

    assert_equal ['before', '  x = 1', 'after'], rows.map(&:text)
    assert_equal [[:code, '  '], [:code, 'x = 1']], rows[1].segments.map(&:reverse)
  end

  def test_highlights_a_ruby_tagged_fence
    rows = Rubycog::Markdown.lines("```ruby\ndef size = 42\n```", 40)

    assert_equal ['  def size = 42'], rows.map(&:text)
    assert_equal [[:code, '  '], [:keyword, 'def'], [nil, ' '], [:method, 'size'],
                  [nil, ' = '], [:number, '42']], rows.first.segments.map(&:reverse)
  end

  def test_leaves_other_and_untagged_fences_in_the_code_colour
    json = Rubycog::Markdown.lines("```json\n{\"if\": true}\n```", 40)
    bare = Rubycog::Markdown.lines("```\nif true then end\n```", 40)

    assert_equal [[:code], [:code]], json.first.segments.map { |_text, style| [style] }
    assert_equal [[:code], [:code]], bare.first.segments.map { |_text, style| [style] }
  end

  def test_recognises_ruby_fence_markers_only
    assert Rubycog::Markdown.ruby_fence?('```ruby')
    assert Rubycog::Markdown.ruby_fence?('```RB')
    assert Rubycog::Markdown.ruby_fence?('```ruby title=demo')
    refute Rubycog::Markdown.ruby_fence?('```')
    refute Rubycog::Markdown.ruby_fence?('```rubyish')
    refute Rubycog::Markdown.ruby_fence?('```python')
  end

  def test_a_ruby_fence_wraps_exactly_like_an_untagged_one
    text = "def greet(name) = 'hello ' + name.to_s # a comment long enough to wrap"

    bare = Rubycog::Markdown.lines("```\n#{text}\n```", 24).map(&:text)
    ruby = Rubycog::Markdown.lines("```ruby\n#{text}\n```", 24).map(&:text)

    assert_equal bare, ruby
    assert(ruby.all? { |row| row.start_with?('  ') && Rubycog::Text.width(row) <= 24 })
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

  def test_highlights_ruby_tokens_for_tool_code
    assert_equal [['def', :keyword], [' ', nil], ['size', :method], [' = ', nil],
                  ['42', :number], [' ', nil], ['# answer', :comment]],
                 ruby_runs('def size = 42 # answer')
  end

  def test_ruby_highlight_keeps_strings_and_scope_operators_intact
    assert_equal [['"a#b n"', :string], [' ', nil], ['# tail', :comment]],
                 ruby_runs('"a#b n" # tail')
    assert_equal [['Foo', :constant], ['::', nil], ['Bar', :constant]], ruby_runs('Foo::Bar')
    assert_equal [[':sym', :symbol]], ruby_runs('x ? :sym : y').reject { |_text, style| style.nil? }
  end

  def test_ruby_highlight_never_drops_characters
    text = %(def greet(name)\n  "hi \#{name}" + %w[a b] # greet\nend)

    text.lines.each do |line|
      source = line.chomp
      assert_equal source, Rubycog::RubyHighlight.chars(source).map(&:first).join
    end
  end

  def test_ruby_lines_wrap_like_plain_code
    text = "'a' + 'bcdefghijklmnopqrstuvwxyz' # a comment long enough to wrap"

    plain = Rubycog::Markdown.code_lines(text, 20).map(&:text)
    ruby = Rubycog::Markdown.ruby_lines(text, 20).map(&:text)

    assert_equal plain, ruby
    assert(ruby.all? { |row| row.start_with?('  ') && Rubycog::Text.width(row) <= 20 })
  end

  def test_inline_markers_do_not_change_where_lines_break
    plain = Rubycog::Markdown.lines('alpha beta gamma delta', 12).map(&:text)
    styled = Rubycog::Markdown.lines('**alpha** beta `gamma` delta', 12).map(&:text)

    assert_equal plain, styled
  end

  def test_renders_no_rows_for_missing_text
    assert_empty Rubycog::Markdown.lines(nil, 20)
  end

  private

  # Runs of [text, style] for one line, with identical neighbours merged, so a
  # test can state the expected highlighting as a short list.
  def ruby_runs(line)
    Rubycog::RubyHighlight.chars(line).chunk_while { |a, b| a[1] == b[1] }
                              .map { |run| [run.map(&:first).join, run.first[1]] }
  end
end
