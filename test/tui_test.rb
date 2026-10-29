# frozen_string_literal: true

require_relative 'test_helper'

class FakeWindow
  attr_reader :rows, :cursor

  def initialize(height, width)
    @rows = Array.new(height) { +'' }
    @width = width
    @cursor = [0, 0]
  end

  def maxy = @rows.length
  def maxx = @width

  def attron(*)
    yield
  end

  def setpos(y, x)
    @cursor = [y, x]
  end

  def addstr(text)
    y, x = @cursor
    @rows[y] = @rows[y].ljust(x) + text
    @cursor = [y, x + text.length]
  end
end

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

  def test_normalizes_printable_characters_returned_by_curses
    tui = Rubycog::TUI.new(FakeChat.new)
    assert_equal 97, tui.send(:normalize_key, 'a')
    assert_equal 3, tui.send(:normalize_key, 3)
  end

  def test_accepts_english_input_from_curses
    tui = Rubycog::TUI.new(FakeChat.new)
    'hello 42!'.each_char { |char| tui.send(:handle_key, tui.send(:normalize_key, char)) }
    assert_equal 'hello 42!', tui.instance_variable_get(:@input)
  end

  def test_approval_accepts_y_and_n_returned_as_characters
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_set(:@approval, Object.new)
    tui.send(:handle_key, tui.send(:normalize_key, 'y'))
    assert_nil tui.instance_variable_get(:@approval)
    assert_equal true, tui.instance_variable_get(:@approvals).pop(true)

    tui.instance_variable_set(:@approval, Object.new)
    tui.send(:handle_key, tui.send(:normalize_key, 'n'))
    assert_nil tui.instance_variable_get(:@approval)
    assert_equal false, tui.instance_variable_get(:@approvals).pop(true)
  end

  def test_header_shows_the_current_directory
    agent = Struct.new(:chat).new(FakeChat.new)
    tui = Rubycog::TUI.new(agent)
    window = FakeWindow.new(10, 120)
    tui.instance_variable_set(:@window, window)
    tui.send(:draw_header, 120)
    assert_includes window.rows[0], Dir.pwd
    assert_includes window.rows[0], 'RubyCog'
    assert_includes window.rows[0], 'fake-model'
  end

  def test_truncates_long_paths_from_the_left
    tui = Rubycog::TUI.new(FakeChat.new)
    assert_equal '/short/path', tui.send(:truncate_path, '/short/path', 20)
    assert_equal '…path', tui.send(:truncate_path, '/very/long/path', 5)
    assert_equal '', tui.send(:truncate_path, '/very/long/path', 1)
  end

  def test_yolo_auto_approves_without_waiting
    tui = Rubycog::TUI.new(FakeChat.new, yolo: true)
    assert_equal true, tui.send(:resolve_approval, Object.new)
    assert tui.instance_variable_get(:@approvals).empty?
    tui.send(:drain_events)
    assert_includes tui.instance_variable_get(:@entries).map { |entry| entry[:text] },
      'eval auto-approved (yolo)'
  end

  def test_yolo_starts_with_a_warning
    tui = Rubycog::TUI.new(FakeChat.new, yolo: true)
    assert_equal :warning, tui.instance_variable_get(:@entries).last[:role]
  end

  def test_yolo_command_toggles_mode
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_set(:@input, +'/yolo')
    tui.send(:submit)
    assert_equal true, tui.instance_variable_get(:@yolo)
    assert_includes tui.instance_variable_get(:@entries).last[:text], 'YOLO on'

    tui.instance_variable_set(:@input, +'/yolo')
    tui.send(:submit)
    assert_equal false, tui.instance_variable_get(:@yolo)
    assert_includes tui.instance_variable_get(:@entries).last[:text], 'YOLO off'
  end

  def test_footer_shows_yolo_mode
    tui = Rubycog::TUI.new(FakeChat.new, yolo: true)
    window = FakeWindow.new(10, 120)
    tui.instance_variable_set(:@window, window)
    tui.send(:draw_footer, 10, 120)
    assert_includes window.rows[7], 'YOLO'
  end

  def test_formats_object_count_and_memory
    tui = Rubycog::TUI.new(FakeChat.new)
    assert_equal '21,367', tui.send(:format_count, 21_367)
    assert_equal '512 KB', tui.send(:format_bytes, 512 * 1024)
    assert_equal '1.5 MB', tui.send(:format_bytes, (1.5 * 1024 * 1024).round)
    assert_equal '2.0 GB', tui.send(:format_bytes, 2 * 1024**3)
    assert_equal 'n/a', tui.send(:format_bytes, nil)
  end

  def test_footer_shows_runtime_stats
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_set(:@objects, 21_367)
    tui.instance_variable_set(:@memory, 52 * 1024 * 1024)
    tui.instance_variable_set(:@stats_at, Process.clock_gettime(Process::CLOCK_MONOTONIC))
    window = FakeWindow.new(10, 160)
    tui.instance_variable_set(:@window, window)
    tui.send(:draw_footer, 10, 160)
    assert_includes window.rows[7], 'obj 21,367'
    assert_includes window.rows[7], 'mem 52.0 MB'
  end

  def test_footer_hides_runtime_stats_when_narrow
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_set(:@objects, 21_367)
    tui.instance_variable_set(:@memory, 52 * 1024 * 1024)
    tui.instance_variable_set(:@stats_at, Process.clock_gettime(Process::CLOCK_MONOTONIC))
    window = FakeWindow.new(10, 60)
    tui.instance_variable_set(:@window, window)
    tui.send(:draw_footer, 10, 60)
    refute_includes window.rows[7], 'obj'
  end

  def test_gc_command_reports_freed_objects_and_memory
    tui = Rubycog::TUI.new(FakeChat.new)
    snapshots = [{ objects: 100_000, memory: 64 * 1024 * 1024 },
                 { objects: 61_000, memory: 48 * 1024 * 1024 }]
    tui.define_singleton_method(:stats_snapshot) { snapshots.shift }
    tui.instance_variable_set(:@input, +'/gc')
    tui.send(:submit)
    entry = tui.instance_variable_get(:@entries).last
    assert_equal :info, entry[:role]
    assert_includes entry[:text], 'freed 39,000 objects'
    assert_includes entry[:text], 'mem 64.0 MB → 48.0 MB'
    assert_equal 61_000, tui.instance_variable_get(:@objects)
  end

  def test_gc_command_collects_garbage_for_real
    tui = Rubycog::TUI.new(FakeChat.new)
    Array.new(20_000) { |i| "garbage-#{i}" }
    tui.instance_variable_set(:@input, +'/gc')
    tui.send(:submit)
    assert_operator tui.instance_variable_get(:@objects), :>, 0
    assert_match(/^GC complete: freed [\d,]+ objects · mem .+ → .+$/,
                 tui.instance_variable_get(:@entries).last[:text])
  end

  def test_gc_report_tolerates_missing_stats
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_set(:@objects, 10)
    tui.instance_variable_set(:@memory, nil)
    text = tui.send(:gc_report, { objects: nil, memory: nil })
    assert_includes text, 'freed objects'
    assert_includes text, 'n/a'
  end

def test_approval_shows_the_code_only_once_after_approving
  tui = Rubycog::TUI.new(FakeChat.new)
  call = Struct.new(:name, :arguments).new('eval', { 'code' => 'x = 1' })
  events = tui.instance_variable_get(:@events)
  events << { type: :approval, payload: call }
  tui.send(:drain_events)
  events << { type: :tool_call, payload: { name: 'eval', code: 'x = 1' } }
  tui.send(:drain_events)
  assert_equal ['x = 1'], tui.instance_variable_get(:@entries).select { |e| e[:role] == :tool }.map { |e| e[:text] }
end

def test_yolo_mode_still_shows_the_code_from_the_tool_call
  tui = Rubycog::TUI.new(FakeChat.new, yolo: true)
  tui.send(:resolve_approval, Struct.new(:name, :arguments).new('eval', { 'code' => 'y = 2' }))
  events = tui.instance_variable_get(:@events)
  events << { type: :tool_call, payload: { name: 'eval', code: 'y = 2' } }
  tui.send(:drain_events)
  assert_equal ['y = 2'], tui.instance_variable_get(:@entries).select { |e| e[:role] == :tool }.map { |e| e[:text] }
end

def test_same_code_run_twice_is_shown_twice
  tui = Rubycog::TUI.new(FakeChat.new)
  events = tui.instance_variable_get(:@events)
  events << { type: :tool_call, payload: { name: 'eval', code: 'z = 3' } }
  events << { type: :tool_result, payload: '3' }
  events << { type: :tool_call, payload: { name: 'eval', code: 'z = 3' } }
  tui.send(:drain_events)
  assert_equal ['z = 3', 'z = 3'], tui.instance_variable_get(:@entries).select { |e| e[:role] == :tool }.map { |e| e[:text] }
end

  def test_help_lists_gc_command
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_set(:@input, +'/help')
    tui.send(:submit)
    assert_includes tui.instance_variable_get(:@entries).last[:text], '/gc'
  end

  def test_refresh_stats_collects_runtime_values
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.send(:refresh_stats)
    assert_operator tui.instance_variable_get(:@objects), :>, 0
    assert_operator tui.instance_variable_get(:@memory), :>, 0
  end
end
