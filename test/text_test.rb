# frozen_string_literal: true

require_relative 'test_helper'

class TextTest < Minitest::Test
  def test_wraps_long_words_and_preserves_blank_lines
    assert_equal %w[ruby cog], Rubycog::Text.wrap('rubycog', 4)
    assert_equal ['a', '', 'b'], Rubycog::Text.wrap("a\n\nb", 4)
    assert_equal ['hello ', 'ruby'], Rubycog::Text.wrap('hello ruby', 6)
  end

  def test_handles_wide_characters
    text = '你好a'
    assert_equal 5, Rubycog::Text.width(text)
    assert_equal %w[你 好 a], Rubycog::Text.wrap(text, 2)
    assert_equal '好', Rubycog::Text.slice(text, 2, 2)
    assert_equal '', Rubycog::Text.slice(text, 1, 1)
  end
end
