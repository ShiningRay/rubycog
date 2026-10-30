# frozen_string_literal: true

require_relative 'test_helper'
require 'minitest/mock'
require 'tmpdir'

class FakeWindow
  attr_reader :rows, :cursor, :masks

  def initialize(height, width)
    @rows = Array.new(height) { +'' }
    @masks = Array.new(height) { 0 }
    @width = width
    @cursor = [0, 0]
    @mask = 0
  end

  def maxy = @rows.length
  def maxx = @width

  def attron(mask = 0)
    @mask = mask
    yield
  ensure
    @mask = 0
  end

  def setpos(y, x)
    @cursor = [y, x]
  end

  def addstr(text)
    y, x = @cursor
    @rows[y] = @rows[y].ljust(x) + text
    @masks[y] |= @mask
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
    assert_includes tui.instance_variable_get(:@entries).last[:text], '/reset-eval'
    assert_includes tui.instance_variable_get(:@entries).last[:text], '/session'
    assert_includes tui.instance_variable_get(:@entries).last[:text], '/compact'
    assert_includes tui.instance_variable_get(:@entries).last[:text], '/restart'
  end

  def test_reset_eval_command_clears_locals
    called = false
    agent = Object.new
    agent.define_singleton_method(:reset_eval) { called = true }
    tui = Rubycog::TUI.new(agent)
    tui.instance_variable_set(:@input, +'/reset-eval')
    tui.send(:submit)

    assert called
    assert_includes tui.instance_variable_get(:@entries).last[:text], 'eval locals cleared'
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

  def test_tool_entries_use_ruby_token_colours
    mask = tool_row_mask('def size = 42', ruby_pairs: true)

    # 6 = keyword (bold), 18 = method name, 9 = number, code colour = indent.
    assert_equal Curses.color_pair(6) | Curses::A_BOLD | Curses.color_pair(18) |
                   Curses.color_pair(9) | Curses.color_pair(Rubycog::TUI::CODE_COLOR), mask
  end

  def test_tool_entries_keep_one_colour_without_token_pairs
    mask = tool_row_mask('def size = 42', ruby_pairs: false)

    assert_equal Curses.color_pair(Rubycog::TUI::CODE_COLOR), mask
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

  def test_entry_rows_are_reused_until_the_text_changes
    tui = Rubycog::TUI.new(FakeChat.new)
    entry = { role: :assistant, text: +'hello' }
    first = tui.send(:entry_rows, entry, 60)
    assert_same first, tui.send(:entry_rows, entry, 60)

    entry[:text] << ' again'
    refute_same first, tui.send(:entry_rows, entry, 60)
  end

  def test_entry_rows_wrap_the_body_between_a_label_and_a_spacer
    tui = Rubycog::TUI.new(FakeChat.new)
    rows = tui.send(:entry_rows, { role: :assistant, text: 'hi' }, 60)

    assert_equal 'RubyCog', rows.first.first.text
    assert_equal '  hi', rows[1].first.text
    assert rows.last.first.empty?
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
    session.define_singleton_method(:save) { |messages, stamps: nil| saved << [messages, stamps] }
    chat = FakeChat.new
    agent = Struct.new(:chat).new(chat)
    tui = Rubycog::TUI.new(agent, session: session)
    tui.define_singleton_method(:restart_problem) { |**| nil }
    tui.instance_variable_set(:@input, +'/restart')

    assert_equal :restart, tui.send(:submit)
    assert_equal [chat.messages, []], saved.first
  end

  def test_restart_is_refused_when_the_bundle_is_not_installed
    saved = []
    session = Object.new
    session.define_singleton_method(:path) { '/tmp/session.json' }
    session.define_singleton_method(:save) { |messages, stamps: nil| saved << [messages, stamps] }
    tui = Rubycog::TUI.new(Struct.new(:chat).new(FakeChat.new), session: session)
    tui.define_singleton_method(:restart_problem) { |**| "Could not find gem 'dotenv' in locally installed gems." }
    tui.instance_variable_set(:@input, +'/restart')

    assert_nil tui.send(:submit)
    assert_equal 1, saved.size, 'the session is still saved before the probe runs'
    assert_includes tui.instance_variable_get(:@entries).last[:text],
      "restart refused: Could not find gem 'dotenv'"
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
    refute tui.instance_variable_get(:@deps_stale)
  end

  def test_gemfile_change_asks_for_bundle_install_instead_of_a_plain_restart
    tui = Rubycog::TUI.new(FakeChat.new)
    gemfile = File.join(Rubycog.root, 'Gemfile')
    tui.instance_variable_set(:@source_digest, { gemfile => [1, 1] })
    tui.define_singleton_method(:source_snapshot) { { gemfile => [2, 1] } }
    tui.send(:refresh_source_state)

    assert tui.instance_variable_get(:@deps_stale)
    window = FakeWindow.new(10, 120)
    tui.instance_variable_set(:@window, window)
    tui.send(:draw_footer, 10, 120)

    assert_includes window.rows[7], 'bundle install'
    assert_includes window.rows[7], '/restart'
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
    session.define_singleton_method(:save) { |messages, stamps: nil| saved << [messages, stamps] }
    chat = FakeChat.new
    tui = Rubycog::TUI.new(Struct.new(:chat).new(chat), session: session)
    tui.instance_variable_set(:@input, +'/restart')

    assert_equal :restart, tui.send(:handle_key, 13)
    assert_equal [chat.messages, []], saved.first
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
    docs = Struct.new(:name, :arguments).new('search_docs', { 'query' => 'approval session' })

    assert_includes Rubycog::ToolPreview.for(edit), 'edit lib/rubycog/agent.rb'
    assert_includes Rubycog::ToolPreview.for(edit), 'fix'
    assert_includes Rubycog::ToolPreview.for(tests), 'test/agent_test.rb'
    assert_includes Rubycog::ToolPreview.for(docs), 'approval session'
  end

  # A TUI whose transcript is far taller than the 12-row fake window (7 body
  # rows), with entries numbered so the visible slice is easy to assert on.
  def scrolling_tui(count = 30)
    tui = Rubycog::TUI.new(FakeChat.new)
    entries = tui.instance_variable_get(:@entries)
    count.times { |i| entries << { role: :info, text: "line #{i}" } }
    window = FakeWindow.new(12, 60)
    tui.instance_variable_set(:@window, window)
    tui.send(:draw_transcript, 12, 60)
    [tui, window]
  end

  # FakeWindow#addstr appends to the existing row, so clear it before redrawing.
  def redraw_transcript(tui, window, height = 12, width = 60)
    window.rows.map! { +'' }
    tui.send(:draw_transcript, height, width)
    window.rows.join("\n")
  end

  def test_page_up_scrolls_back_through_history
    tui, window = scrolling_tui
    assert_includes redraw_transcript(tui, window), 'line 29'

    20.times do
      tui.send(:handle_key, Curses::KEY_PPAGE)
      redraw_transcript(tui, window)
    end
    drawn = redraw_transcript(tui, window)

    assert_includes drawn, 'line 0'
    refute_includes drawn, 'line 29'
  end

  def test_scrolled_view_stays_put_while_output_streams_in
    tui, window = scrolling_tui
    tui.send(:handle_key, Curses::KEY_PPAGE)
    before = redraw_transcript(tui, window)

    tui.instance_variable_get(:@entries) << { role: :info, text: 'fresh output' }
    assert_equal before, redraw_transcript(tui, window)
  end

  def test_scrolling_down_past_the_end_follows_the_tail_again
    tui, window = scrolling_tui
    tui.send(:handle_key, Curses::KEY_PPAGE)
    redraw_transcript(tui, window)
    refute_nil tui.instance_variable_get(:@top)

    tui.send(:handle_key, Curses::KEY_NPAGE)
    assert_nil tui.instance_variable_get(:@top)
    assert_includes redraw_transcript(tui, window), 'line 29'
  end

  def test_scrolling_works_while_a_turn_is_running
    tui, window = scrolling_tui
    redraw_transcript(tui, window)
    tui.instance_variable_set(:@busy, true)

    tui.send(:handle_key, Curses::KEY_UP)
    refute_nil tui.instance_variable_get(:@top)

    tui.send(:handle_key, tui.send(:normalize_key, 'a'))
    assert_equal '', tui.instance_variable_get(:@input)
  end

  def test_empty_enter_returns_to_the_newest_output
    tui, window = scrolling_tui
    redraw_transcript(tui, window)
    tui.send(:handle_key, Curses::KEY_PPAGE)
    refute_nil tui.instance_variable_get(:@top)

    tui.send(:handle_key, 10)
    assert_nil tui.instance_variable_get(:@top)
  end

  def test_footer_reports_a_scrolled_back_transcript
    tui, window = scrolling_tui
    redraw_transcript(tui, window)
    tui.send(:handle_key, Curses::KEY_PPAGE)
    redraw_transcript(tui, window)
    window.rows.map! { +'' }
    tui.send(:draw_footer, 12, 60)

    assert_includes window.rows[9], 'scrolled back'
    assert_includes window.rows[9], 'Enter returns to the end'
  end

  def test_draws_inline_markdown_with_its_own_attributes
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_get(:@entries) << { role: :assistant, text: "plain **bold**\n`code` *soft*" }
    window = FakeWindow.new(20, 60)
    tui.instance_variable_set(:@window, window)
    tui.send(:draw_transcript, 20, 60)

    bold_row = window.rows.index { |row| row.include?('plain bold') }
    code_row = window.rows.index { |row| row.include?('code soft') }
    refute_includes window.rows[bold_row], '*'
    refute_includes window.rows[code_row], '`'
    assert_equal Curses::A_BOLD, window.masks[bold_row] & Curses::A_BOLD
    assert_equal 0, window.masks[bold_row] & Curses.color_pair(Rubycog::TUI::CODE_COLOR)
    assert_equal Curses.color_pair(Rubycog::TUI::CODE_COLOR),
      window.masks[code_row] & Curses.color_pair(Rubycog::TUI::CODE_COLOR)
    assert_equal Curses::A_UNDERLINE, window.masks[code_row] & Curses::A_UNDERLINE
  end

  # Types text the way curses delivers it: one byte per handle_key call.
  def type_text(tui, text)
    text.each_byte { |byte| tui.send(:handle_key, byte) }
  end

  def test_ctrl_f_finds_the_nearest_match_above_the_viewport
    tui, window = scrolling_tui
    tui.send(:handle_key, Rubycog::TUI::SEARCH_KEY)
    type_text(tui, 'line 2')

    assert_equal 'line 2', tui.instance_variable_get(:@search)
    assert_includes redraw_transcript(tui, window), 'line 29'
  end

  def test_enter_walks_older_and_wraps_past_the_oldest_match
    tui = Rubycog::TUI.new(FakeChat.new)
    entries = tui.instance_variable_get(:@entries)
    entries << { role: :info, text: 'first needle' }
    10.times { |i| entries << { role: :info, text: "filler #{i}" } }
    entries << { role: :info, text: 'second needle' }
    tui.instance_variable_set(:@window, FakeWindow.new(12, 60))
    tui.send(:draw_transcript, 12, 60)

    tui.send(:handle_key, Rubycog::TUI::SEARCH_KEY)
    type_text(tui, 'needle')
    oldest = tui.instance_variable_get(:@top)
    tui.send(:handle_key, 10)
    wrapped = tui.instance_variable_get(:@top)

    assert_operator wrapped, :>, oldest, 'Enter wraps to the newest match'
    tui.send(:handle_key, 10)
    assert_operator tui.instance_variable_get(:@top), :<, wrapped, 'and walks older again'
  end

  def test_search_reports_when_nothing_matches
    tui, window = scrolling_tui
    tui.send(:handle_key, Rubycog::TUI::SEARCH_KEY)
    type_text(tui, 'zzz')
    window.rows.map! { +'' }
    tui.send(:draw_footer, 12, 60)

    assert_nil tui.instance_variable_get(:@top)
    assert_includes window.rows[9], 'no match'
    assert_includes window.rows[9], 'Esc close'
  end

  def test_search_footer_counts_the_matches
    tui, window = scrolling_tui
    tui.send(:handle_key, Rubycog::TUI::SEARCH_KEY)
    type_text(tui, 'line 1')
    window.rows.map! { +'' }
    tui.send(:draw_footer, 12, 60)

    assert_includes window.rows[9], '11 matches'
  end

  def test_ctrl_f_again_steps_to_the_next_match
    tui, window = scrolling_tui
    redraw_transcript(tui, window)
    tui.send(:handle_key, Rubycog::TUI::SEARCH_KEY)
    type_text(tui, 'line 1')
    before = tui.instance_variable_get(:@top)
    tui.send(:handle_key, Rubycog::TUI::SEARCH_KEY)

    assert_operator tui.instance_variable_get(:@top), :<, before
  end

  def test_backspace_edits_the_search_query
    tui, = scrolling_tui
    tui.send(:handle_key, Rubycog::TUI::SEARCH_KEY)
    type_text(tui, 'line 29')
    tui.send(:handle_key, 127)

    assert_equal 'line 2', tui.instance_variable_get(:@search)
  end

  def test_escape_and_ctrl_c_close_the_search_without_quitting
    tui, = scrolling_tui
    tui.send(:handle_key, Rubycog::TUI::SEARCH_KEY)
    assert_nil tui.send(:handle_key, 27)
    assert_nil tui.instance_variable_get(:@search)

    tui.send(:handle_key, Rubycog::TUI::SEARCH_KEY)
    assert_nil tui.send(:handle_key, 3)
    assert_nil tui.instance_variable_get(:@search)
    assert_equal :quit, tui.send(:handle_key, 3)
  end

  def test_search_works_while_a_turn_is_running
    tui, window = scrolling_tui
    redraw_transcript(tui, window)
    tui.instance_variable_set(:@busy, true)
    tui.send(:handle_key, Rubycog::TUI::SEARCH_KEY)
    type_text(tui, 'line 5')

    assert_equal 'line 5', tui.instance_variable_get(:@search)
    assert_equal '', tui.instance_variable_get(:@input)
  end

  def test_input_line_shows_the_search_query
    tui, window = scrolling_tui
    tui.send(:handle_key, Rubycog::TUI::SEARCH_KEY)
    type_text(tui, 'abc')
    window.rows.map! { +'' }
    Curses.stub(:curs_set, nil) { tui.send(:draw_input, 12, 60) }

    assert_includes window.rows.last, 'find> abc'
  end

  # Delivers a mouse event the way curses does: KEY_MOUSE, then Curses.getmouse.
  def wheel(tui, bstate)
    event = Struct.new(:bstate).new(bstate)
    Curses.stub(:getmouse, event) { tui.send(:handle_key, Curses::KEY_MOUSE) }
  end

  def test_wheel_up_scrolls_back_by_one_notch
    tui, window = scrolling_tui
    redraw_transcript(tui, window)
    wheel(tui, Rubycog::TUI::WHEEL_UP)

    bottom = tui.instance_variable_get(:@row_count) - tui.instance_variable_get(:@body_height)
    assert_equal bottom - Rubycog::TUI::WHEEL_STEP, tui.instance_variable_get(:@top)
  end

  def test_wheel_down_returns_to_the_tail
    tui, window = scrolling_tui
    redraw_transcript(tui, window)
    wheel(tui, Rubycog::TUI::WHEEL_UP)
    wheel(tui, Rubycog::TUI::WHEEL_DOWN)

    assert_nil tui.instance_variable_get(:@top)
    assert_includes redraw_transcript(tui, window), 'line 29'
  end

  def test_other_mouse_events_are_ignored
    tui, window = scrolling_tui
    redraw_transcript(tui, window)
    wheel(tui, Curses::BUTTON1_PRESSED)

    assert_nil tui.instance_variable_get(:@top)
  end

  def test_wheel_works_while_a_turn_is_running
    tui, window = scrolling_tui
    redraw_transcript(tui, window)
    tui.instance_variable_set(:@busy, true)
    wheel(tui, Rubycog::TUI::WHEEL_UP)

    refute_nil tui.instance_variable_get(:@top)
  end

  def test_wheel_bits_match_what_ncurses_reports
    # Measured on ncurses 6.0: wheel up arrives as KEY_MOUSE with bstate 524288.
    assert_equal 524_288, Rubycog::TUI::WHEEL_UP
    assert_equal 33_554_432, Rubycog::TUI::WHEEL_DOWN
  end

  def test_mouse_reporting_is_enabled_only_when_both_wheel_directions_decode
    tui = Rubycog::TUI.new(FakeChat.new)
    masks = []
    Curses.stub(:mousemask, ->(mask) { masks << mask; 0 }) { tui.send(:enable_mouse) }

    if Rubycog::TUI::WHEEL_SUPPORTED
      assert_equal [Rubycog::TUI::WHEEL_UP | Rubycog::TUI::WHEEL_DOWN], masks
    else
      assert_empty masks
    end
  end

  # Turn timing. The tests backdate @turn_started_at instead of sleeping.
  def test_finished_turn_records_how_long_it_took
    tui = Rubycog::TUI.new(FakeChat.new)
    events = tui.instance_variable_get(:@events)
    tui.instance_variable_get(:@entries) << { role: :user, text: 'hi' }
    tui.send(:start_turn)
    events << { type: :text, payload: 'the answer' }
    tui.send(:drain_events)
    tui.instance_variable_set(:@turn_started_at, tui.send(:monotonic) - 3.25)
    events << { type: :done, payload: nil }
    tui.send(:drain_events)

    answer = tui.instance_variable_get(:@entries).reverse_each.find { |entry| entry[:role] == :assistant }
    assert_in_delta 3.25, answer[:elapsed], 0.2
    assert_nil tui.instance_variable_get(:@turn_started_at)
  end

  def test_cancelled_turn_records_the_duration_on_the_question
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_get(:@entries) << { role: :user, text: 'hi' }
    tui.send(:start_turn)
    tui.instance_variable_set(:@turn_started_at, tui.send(:monotonic) - 1.5)
    tui.instance_variable_get(:@events) << { type: :done, payload: nil }
    tui.send(:drain_events)

    question = tui.instance_variable_get(:@entries).last
    assert_equal :user, question[:role]
    assert_in_delta 1.5, question[:elapsed], 0.2
  end

  def test_transcript_shows_the_duration_next_to_the_answer
    tui = Rubycog::TUI.new(FakeChat.new)
    window = FakeWindow.new(20, 60)
    tui.instance_variable_set(:@window, window)
    events = tui.instance_variable_get(:@events)
    tui.instance_variable_get(:@entries) << { role: :user, text: 'hi' }
    tui.send(:start_turn)
    events << { type: :text, payload: 'the answer' }
    tui.send(:drain_events)
    now = Time.now
    tui.instance_variable_get(:@entries).last[:at] = Time.local(now.year, now.month, now.day, 9, 5)
    tui.send(:draw_transcript, 20, 60) # lays the turn out and caches its rows
    tui.instance_variable_set(:@turn_started_at, tui.send(:monotonic) - 3.2)
    events << { type: :done, payload: nil }
    tui.send(:drain_events)
    window.rows.each(&:clear)
    tui.send(:draw_transcript, 20, 60)

    assert_includes window.rows.join("\n"), 'RubyCog · 09:05 · 3.2s'
  end

  def test_footer_shows_the_running_turn_clock
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_set(:@busy, true)
    tui.instance_variable_set(:@status, 'thinking')
    tui.instance_variable_set(:@turn_started_at, tui.send(:monotonic) - 42)
    window = FakeWindow.new(10, 120)
    tui.instance_variable_set(:@window, window)
    tui.send(:draw_footer, 10, 120)
    drawn = window.rows.join("\n")

    assert_includes drawn, 'thinking · 42s'
    assert_includes drawn, 'Ctrl-C cancel'
  end

  # Status pulse. Frames are placed on the monotonic clock, so the tests pin
  # that clock instead of sleeping.
  def test_running_status_pulses_through_its_colour_frames
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_set(:@pulse_pairs, [10, 11, 12])
    clock = 0.0
    tui.define_singleton_method(:monotonic) { clock }

    pairs = Array.new(5) do |step|
      clock = step * Rubycog::TUI::PULSE_STEP
      tui.send(:pulse_style).first
    end

    assert_equal [10, 11, 12, 10, 11], pairs
    assert_equal Curses::A_BOLD, tui.send(:pulse_style).last
  end

  def test_running_status_falls_back_to_bold_without_colour_frames
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_set(:@pulse_pairs, [])

    assert_equal [0, Curses::A_BOLD], tui.send(:pulse_style)
  end

  def test_busy_footer_paints_the_status_with_the_pulse_colour
    tui, window = busy_tui([10, 11, 12])
    tui.send(:draw_footer, 10, 120)
    drawn = window.rows.join("\n")

    assert_includes drawn, 'thinking · 3.0s'
    assert_includes drawn, 'Ctrl-C cancel'
    assert window.masks[7].anybits?(Curses.color_pair(10) | Curses::A_BOLD)
  end

  def test_busy_footer_colour_advances_to_the_next_frame
    tui, window = busy_tui([10, 11, 12])
    clock = 0.0
    tui.define_singleton_method(:monotonic) { clock }
    tui.send(:draw_footer, 10, 120)
    first = window.masks[7]

    window = FakeWindow.new(10, 120) # masks accumulate, so start from a clean one
    tui.instance_variable_set(:@window, window)
    clock = Rubycog::TUI::PULSE_STEP
    tui.send(:draw_footer, 10, 120)

    refute_equal first, window.masks[7]
    assert window.masks[7].anybits?(Curses.color_pair(11))
  end

  def test_idle_footer_stays_uncoloured
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_set(:@pulse_pairs, [10, 11, 12])
    window = FakeWindow.new(10, 120)
    tui.instance_variable_set(:@window, window)
    tui.send(:draw_footer, 10, 120)

    assert_equal 0, window.masks[7]
  end

  # A TUI mid-turn with a fixed set of pulse pairs, plus its fake screen.
  def busy_tui(frames)
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_set(:@busy, true)
    tui.instance_variable_set(:@status, 'thinking')
    tui.instance_variable_set(:@pulse_pairs, frames)
    tui.instance_variable_set(:@turn_started_at, tui.send(:monotonic) - 3)
    window = FakeWindow.new(10, 120)
    tui.instance_variable_set(:@window, window)
    [tui, window]
  end

  def test_live_clock_repaints_only_while_a_turn_runs
    tui = Rubycog::TUI.new(FakeChat.new)
    refute tui.send(:live_tick?)

    tui.instance_variable_get(:@entries) << { role: :user, text: 'hi' }
    tui.send(:start_turn)
    assert tui.send(:live_tick?)
    refute tui.send(:live_tick?) # throttled to TICK_INTERVAL
  end

  def test_duration_formatting
    tui = Rubycog::TUI.new(FakeChat.new)

    assert_equal '0.8s', tui.send(:format_duration, 0.84)
    assert_equal '42s', tui.send(:format_duration, 42.4)
    assert_equal '2m 05s', tui.send(:format_duration, 125.0)
  end

  def test_sent_question_is_timestamped
    chat = FakeChat.new
    agent = Struct.new(:chat) { def ask(*) = nil }
    tui = Rubycog::TUI.new(agent.new(chat))
    tui.instance_variable_set(:@input, +'hi')
    before = Time.now
    tui.send(:submit)
    tui.instance_variable_get(:@worker).join(2)

    at = tui.instance_variable_get(:@entries).find { |entry| entry[:role] == :user }[:at]
    assert_operator at, :>=, before
    assert_operator at, :<=, Time.now
  end

  def test_transcript_shows_when_a_message_was_written
    tui = Rubycog::TUI.new(FakeChat.new)
    now = Time.now
    tui.instance_variable_get(:@entries) << { role: :user, text: 'hi',
                                              at: Time.local(now.year, now.month, now.day, 9, 5) }
    window = FakeWindow.new(20, 60)
    tui.instance_variable_set(:@window, window)
    tui.send(:draw_transcript, 20, 60)

    assert_includes window.rows.join("\n"), 'You · 09:05'
  end

  def test_resumed_turns_carry_the_saved_time
    history = [{ 'role' => 'user', 'content' => 'earlier', 'at' => '2024-05-03T12:00:00Z' }]
    tui = Rubycog::TUI.new(FakeChat.new, history: history)

    entry = tui.instance_variable_get(:@entries).find { |candidate| candidate[:role] == :user }
    assert_equal Time.utc(2024, 5, 3, 12, 0, 0), entry[:at]
  end

  def test_older_timestamps_show_the_date_and_today_shows_only_the_clock
    tui = Rubycog::TUI.new(FakeChat.new)
    now = Time.now

    assert_equal now.strftime('%H:%M'), tui.send(:format_clock, now)
    assert_equal '05-03 09:05', tui.send(:format_clock, Time.local(2024, 5, 3, 9, 5))
    assert_equal '', tui.send(:format_clock, nil)
  end

  def test_restart_passes_the_message_times_to_the_session
    saved = []
    session = Object.new
    session.define_singleton_method(:path) { '/tmp/session.json' }
    session.define_singleton_method(:save) { |messages, stamps: nil| saved << stamps }
    tui = Rubycog::TUI.new(Struct.new(:chat).new(FakeChat.new), session: session)
    at = Time.utc(2024, 5, 3, 12, 0, 0)
    tui.instance_variable_get(:@entries) << { role: :user, text: 'hi', at: at }
    tui.instance_variable_get(:@entries) << { role: :info, text: 'not a message' }
    tui.instance_variable_set(:@input, +'/restart')

    assert_equal :restart, tui.send(:submit)
    assert_equal [{ role: :user, text: 'hi', at: at }], saved.first
  end

  def test_read_source_results_use_their_file_type_colours
    tui = Rubycog::TUI.new(FakeChat.new)
    entry = { role: :result, text: "# data.json (lines 1-1)\n   1 | { \"ok\": true }" }

    styles = tui.send(:body_rows, entry, 60).flat_map { |row| row.segments.map(&:last) }

    assert_includes styles, :keyword
    assert_includes styles, :string
  end

  def test_results_that_are_not_source_still_render_as_markdown
    tui = Rubycog::TUI.new(FakeChat.new)
    entry = { role: :result, text: 'plain *soft* output' }

    styles = tui.send(:body_rows, entry, 60).flat_map { |row| row.segments.map(&:last) }

    assert_includes styles, :italic
  end

  def test_every_highlighter_style_has_a_colour
    used = Rubycog::CodeHighlight::STYLE_FOR.values + Rubycog::RubyHighlight::STYLE_FOR.values + [:heading, :code]

    assert_empty used.uniq - Rubycog::TUI::STYLES.keys
  end

  private

  # Draws one tool entry and returns the attribute mask of its code row, with
  # the token colours either available or refused.
  def tool_row_mask(code, ruby_pairs:)
    tui = Rubycog::TUI.new(FakeChat.new)
    tui.instance_variable_set(:@ruby_pairs, ruby_pairs)
    tui.instance_variable_get(:@entries) << { role: :tool, text: code }
    window = FakeWindow.new(20, 60)
    tui.instance_variable_set(:@window, window)
    tui.send(:draw_transcript, 20, 60)
    window.masks[window.rows.index { |text| text.include?(code) }]
  end
end
