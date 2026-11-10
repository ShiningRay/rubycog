# frozen_string_literal: true

require_relative 'test_helper'
require 'fileutils'
require 'json'
require 'stringio'
require 'time'
require 'tmpdir'

# Records tool approvals so the headless auto-approval can be asserted.
class RecordingChat < FakeChat
  attr_reader :approvals

  def initialize(**options)
    super
    @approvals = []
  end

  def approve(call)
    @approvals << call
    super
  end
end

# Fails the first prompt and succeeds afterwards, so the daemon has to survive
# a task that raises and keep processing the remaining files.
class FlakyChat < FakeChat
  def initialize(**options)
    super
    @asks = 0
  end

  def ask(question)
    @asks += 1
    raise 'scripted failure' if @asks == 1

    super
  end
end

# Covers the runtime that lets a supervisor run RubyCog without curses: the
# plain-text event stream, auto-approved tools, the one-shot prompt and the
# inbox daemon with its heartbeat and failure isolation.
class HeadlessTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-headless')
    @inbox = File.join(@dir, 'inbox')
    @heartbeat = File.join(@dir, 'heartbeat.json')
    @out = StringIO.new
    @err = StringIO.new
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_one_shot_prints_the_stream_and_succeeds
    headless = build(FakeChat.new)

    assert_equal 0, headless.run(task: 'Use Ruby to calculate 21 * 2')

    assert_includes @out.string, 'I will calculate it.'
    assert_includes @out.string, 'The answer is 42.'
    assert_includes @out.string, '[status]'
    assert_includes @out.string, '[done] ok'
    assert_includes @err.string, "pid=#{Process.pid}"
  end

  def test_tool_calls_are_auto_approved
    chat = RecordingChat.new
    headless = build(chat)

    assert_equal 0, headless.run(task: 'calculate')

    refute chat.awaiting_approval?
    assert_equal ['eval'], chat.approvals.map(&:name)
    assert_includes @out.string, '[approval] auto-approved eval: 6 * 7'
    assert_includes @out.string, '[tool] eval'
  end

  def test_daemon_processes_an_inbox_file_and_writes_the_heartbeat
    FileUtils.mkdir_p(@inbox)
    File.write(File.join(@inbox, 'task.txt'), 'Use Ruby to calculate 21 * 2')
    headless = build(FakeChat.new)

    assert_equal 1, headless.tick

    refute File.exist?(File.join(@inbox, 'task.txt'))
    assert File.exist?(File.join(@inbox, 'done', 'task.txt'))
    heartbeat = JSON.parse(File.read(@heartbeat))
    assert_equal Process.pid, heartbeat['pid']
    assert_equal 1, heartbeat['tasks_done']
    assert Time.iso8601(heartbeat['last_tick'])
    assert Time.iso8601(heartbeat['started_at'])
    assert_includes @out.string, '[inbox] task.txt -> done'
  end

  def test_daemon_survives_a_task_that_raises
    FileUtils.mkdir_p(@inbox)
    File.write(File.join(@inbox, 'a-bad.txt'), 'boom')
    File.write(File.join(@inbox, 'b-good.txt'), 'Use Ruby to calculate 21 * 2')
    headless = build(FlakyChat.new)

    assert_equal 1, headless.tick

    assert File.exist?(File.join(@inbox, 'failed', 'a-bad.txt'))
    assert File.exist?(File.join(@inbox, 'done', 'b-good.txt'))
    assert_includes @out.string, '[error]'
    assert_equal 1, headless.tasks_done
  end

  def test_fatal_error_outside_task_handling_returns_one_with_a_backtrace
    blocker = File.join(@dir, 'not-a-directory')
    File.write(blocker, 'x')
    headless = build(FakeChat.new, inbox: File.join(blocker, 'inbox'))

    assert_equal 1, headless.run(daemon: true)

    assert_includes @err.string, 'rubycog:'
    assert_match(/\.rb:\d+/, @err.string)
  end

  private

  # Builds an agent around a scripted chat and a session inside the temp dir.
  def build(chat, inbox: @inbox)
    session = Rubycog::Session.new(File.join(@dir, 'session.json'))
    agent = Rubycog::Agent.new(chat: chat, session: session, tools: [])
    Rubycog::Headless.new(agent, stdout: @out, stderr: @err, inbox: inbox,
                                 heartbeat: @heartbeat, interval: 0.01)
  end
end
