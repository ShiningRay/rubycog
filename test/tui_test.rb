# frozen_string_literal: true

require_relative 'test_helper'

class TUITest < Minitest::Test
  def test_displays_streamed_text_and_tool_output
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_get(:@events) << { type: :text, payload: 'hello' }
    tui.instance_variable_get(:@events) << { type: :text, payload: ' world' }
    tui.instance_variable_get(:@events) << { type: :text_end, payload: nil }
    tui.instance_variable_get(:@events) << { type: :tool_result, payload: '42' }
    tui.send(:drain_events)
    assert_equal ['hello world', '42'],
      tui.instance_variable_get(:@entries).map { |entry| entry[:text] }.last(2)
  end

  def test_handles_utf8_input_and_editing
    tui = Rubycog::TUI.new(FakeChat.new)
    '你好a'.bytes.each { |byte| tui.send(:append_input, byte) }
    assert_equal '你好a', tui.instance_variable_get(:@input)
    tui.send(:handle_key, Curses::KEY_LEFT)
    tui.send(:handle_key, Curses::KEY_BACKSPACE)
    assert_equal '你a', tui.instance_variable_get(:@input)
  end
end
