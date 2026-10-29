# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

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
      'tool auto-approved (yolo)'
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

  def test_drawing_the_footer_never_samples_stats
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.define_singleton_method(:stats_snapshot) { flunk 'drawing must not fork for stats' }
    tui.instance_variable_set(:@objects, 4242)
    tui.instance_variable_set(:@memory, 2 * 1024 * 1024)
    window = FakeWindow.new(10, 160)
    tui.instance_variable_set(:@window, window)
    tui.send(:draw_footer, 10, 160)

    assert_includes window.rows[7], 'obj 4,242'
  end

  def test_sample_stats_refreshes_values_and_requests_a_repaint
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.define_singleton_method(:stats_snapshot) { { objects: 4242, memory: 2 * 1024 * 1024 } }
    tui.send(:sample_stats)

    assert_equal 4242, tui.instance_variable_get(:@objects)
    assert_equal 1, tui.instance_variable_get(:@events).size
    assert_equal 1, tui.send(:drain_events)
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
    assert_includes tui.instance_variable_get(:@entries).last[:text], '/session'
    assert_includes tui.instance_variable_get(:@entries).last[:text], '/compact'
    assert_includes tui.instance_variable_get(:@entries).last[:text], '/restart'
  end

  def test_compact_command_runs_on_the_worker_thread
    tui = Rubycog::TUI.new(compacting_agent(FakeChat.new, 'a summary'))
    tui.instance_variable_set(:@input, +'/compact')
    tui.send(:submit)
    tui.instance_variable_get(:@worker).join(2)
    tui.send(:drain_events)

    assert_includes tui.instance_variable_get(:@entries).last[:text], 'Compacted the earlier turns'
    refute tui.instance_variable_get(:@busy)
  end

  def test_compact_command_waits_for_the_current_step
    chat = FakeChat.new
    chat.define_singleton_method(:complete?) { false }
    tui = Rubycog::TUI.new(compacting_agent(chat, 'a summary'))
    tui.instance_variable_set(:@input, +'/compact')
    tui.send(:submit)

    assert_includes tui.instance_variable_get(:@entries).last[:text], 'Finish the current step'
    refute tui.instance_variable_get(:@busy)
  end

  # Minimal agent double: a chat, and a compact that returns a fixed summary.
  def compacting_agent(chat, summary)
    agent = Object.new
    agent.define_singleton_method(:chat) { chat }
    agent.define_singleton_method(:compact) { |&_block| summary }
    agent
  end

  def test_draws_fenced_code_indented_and_without_fences
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_get(:@entries) << { role: :assistant,
                                              text: "## Plan\nTry this:\n```ruby\nx = 1\n```\ndone" }
    window = FakeWindow.new(20, 60)
    tui.instance_variable_set(:@window, window)
    tui.send(:draw_transcript, 20, 60)
    drawn = window.rows.join("\n")

    assert_includes drawn, '    x = 1'
    assert_includes drawn, 'Try this:'
    assert_includes drawn, 'Plan'
    refute_includes drawn, '```'
    refute_includes drawn, '##'
  end

  def test_tool_entries_are_drawn_as_code
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_get(:@entries) << { role: :tool, text: "a = 1\nb = 2" }
    window = FakeWindow.new(20, 60)
    tui.instance_variable_set(:@window, window)
    tui.send(:draw_transcript, 20, 60)

    assert_includes window.rows.join("\n"), '    b = 2'
  end

  def test_transcript_rows_are_cached_until_the_text_changes
    tui = Rubycog::TUI.new(FakeChat.new)
    entry = { role: :assistant, text: +'hello there' }
    first = tui.send(:body_rows, entry, 60)
    assert_same first, tui.send(:body_rows, entry, 60)

    entry[:text] << ' again'
    refute_same first, tui.send(:body_rows, entry, 60)
  end

  def test_cached_rows_are_rebuilt_when_the_width_changes
    tui = Rubycog::TUI.new(FakeChat.new)
    entry = { role: :assistant, text: 'word ' * 40 }
    wide = tui.send(:body_rows, entry, 60)
    narrow = tui.send(:body_rows, entry, 30)

    refute_same wide, narrow
    assert_operator narrow.length, :>, wide.length
  end

  def test_drain_events_reports_how_many_events_were_handled
    tui = Rubycog::TUI.new(FakeChat.new)
    assert_equal 0, tui.send(:drain_events)

    events = tui.instance_variable_get(:@events)
    events << { type: :text, payload: 'hi' }
    events << { type: :text_end, payload: nil }
    assert_equal 2, tui.send(:drain_events)
  end

  def test_session_command_reports_path_and_turns
    session = Rubycog::Session.new('/tmp/rubycog-test-session.json')
    session.define_singleton_method(:messages) { [{ 'role' => 'user', 'content' => 'x' }] }
    tui = Rubycog::TUI.new(FakeChat.new, session: session)
    tui.instance_variable_set(:@input, +'/session')
    tui.send(:submit)

    text = tui.instance_variable_get(:@entries).last[:text]
    assert_includes text, '/tmp/rubycog-test-session.json'
    assert_includes text, '1 turns'
  end

  def test_shows_resumed_session_count_and_path
    session = Struct.new(:path).new('/tmp/session.json')
    tui = Rubycog::TUI.new(FakeChat.new, history: [{ 'role' => 'user', 'content' => 'old' }],
                                         session: session)
    entries = tui.instance_variable_get(:@entries)

    assert_equal 'old', entries[1][:text]
    assert_equal 'Resumed 1 turns from /tmp/session.json', entries[2][:text]
    assert_equal 'resumed 1 turns', tui.instance_variable_get(:@status)
  end

  def test_shows_new_session_path
    session = Struct.new(:path).new('/tmp/session.json')
    tui = Rubycog::TUI.new(FakeChat.new, session: session)

    assert_includes tui.instance_variable_get(:@entries).map { |entry| entry[:text] },
      'New session: /tmp/session.json'
    assert_equal 'new session', tui.instance_variable_get(:@status)
  end

  def test_restart_saves_the_session_and_returns_restart
    saved = []
    session = Object.new
    session.define_singleton_method(:path) { '/tmp/session.json' }
    session.define_singleton_method(:save) { |messages| saved << messages }
    chat = FakeChat.new
    agent = Struct.new(:chat).new(chat)
    tui = Rubycog::TUI.new(agent, session: session)
    tui.instance_variable_set(:@input, +'/restart')

    assert_equal :restart, tui.send(:submit)
    assert_equal [chat.messages], saved
  end

  def test_footer_marks_code_changes_as_needing_restart
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_set(:@source_stale, true)
    tui.instance_variable_set(:@stats_at, Process.clock_gettime(Process::CLOCK_MONOTONIC))
    window = FakeWindow.new(10, 120)
    tui.instance_variable_set(:@window, window)
    tui.send(:draw_footer, 10, 120)

    assert_includes window.rows[7], '/restart'
  end

  def test_detects_source_changes
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_set(:@source_digest, { 'a' => [1, 1] })
    tui.define_singleton_method(:source_snapshot) { { 'a' => [2, 1] } }

    tui.send(:refresh_source_state)

    assert tui.instance_variable_get(:@source_stale)
  end

  def test_refresh_stats_collects_runtime_values
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.send(:refresh_stats)
    assert_operator tui.instance_variable_get(:@objects), :>, 0
    assert_operator tui.instance_variable_get(:@memory), :>, 0
  end

  def test_enter_returns_quit_for_quit_command
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_set(:@input, +'/quit')

    assert_equal :quit, tui.send(:handle_key, 10)
  end

  def test_enter_returns_restart_for_restart_command
    saved = []
    session = Struct.new(:path).new('/tmp/session.json')
    session.define_singleton_method(:save) { |messages| saved << messages }
    chat = FakeChat.new
    tui = Rubycog::TUI.new(Struct.new(:chat).new(chat), session: session)
    tui.instance_variable_set(:@input, +'/restart')

    assert_equal :restart, tui.send(:handle_key, 13)
    assert_equal [chat.messages], saved
  end

  def test_self_command_reports_iteration_history
    dir = Dir.mktmpdir('rubycog-tui-self')
    iteration = Rubycog::SelfIteration.new(path: File.join(dir, 'self.json'))
    iteration.record_edit(path: 'lib/rubycog/agent.rb', reason: 'fix', ok: true)
    tui = Rubycog::TUI.new(FakeChat.new, self_iteration: iteration)
    tui.instance_variable_set(:@input, +'/self')
    tui.send(:submit)

    assert_includes tui.instance_variable_get(:@entries).last[:text], 'lib/rubycog/agent.rb'
  ensure
    FileUtils.remove_entry(dir)
  end

  def test_footer_names_the_pending_tool
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_set(:@approval, Struct.new(:name).new('edit_source'))
    window = FakeWindow.new(10, 120)
    tui.instance_variable_set(:@window, window)
    tui.send(:draw_footer, 10, 120)

    assert_includes window.rows[7], 'Run edit_source?'
  end

  def test_tool_preview_describes_edit_and_test_calls
    edit = Struct.new(:name, :arguments).new('edit_source',
                                             { 'path' => 'lib/rubycog/agent.rb', 'reason' => 'fix' })
    tests = Struct.new(:name, :arguments).new('run_tests', { 'paths' => 'test/agent_test.rb' })

    assert_includes Rubycog::ToolPreview.for(edit), 'edit lib/rubycog/agent.rb'
    assert_includes Rubycog::ToolPreview.for(edit), 'fix'
    assert_includes Rubycog::ToolPreview.for(tests), 'test/agent_test.rb'
  end
end
