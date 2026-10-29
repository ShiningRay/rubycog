# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

class SessionTest < Minitest::Test
  class RecordingChat
    attr_reader :added

    def initialize = @added = []

    def add_message(role:, content:) = @added << [role, content]
  end

  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, 'session.json')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_saves_and_reloads_turns
    turns = [{ 'role' => 'user', 'content' => '你好' }, { 'role' => 'assistant', 'content' => 'hi' }]
    Rubycog::Session.new(@path).save(turns)

    assert_equal turns, Rubycog::Session.new(@path).messages
  end

  def test_restores_turns_into_a_chat
    Rubycog::Session.new(@path).save([{ 'role' => 'user', 'content' => 'earlier' }])
    chat = RecordingChat.new

    Rubycog::Session.new(@path).restore(chat)

    assert_equal [['user', 'earlier']], chat.added
  end

  def test_missing_file_starts_empty
    assert_empty Rubycog::Session.new(File.join(@dir, 'nope.json')).messages
  end

  def test_corrupt_file_starts_empty_instead_of_crashing
    File.write(@path, '{"messages": [ oops')

    assert_empty Rubycog::Session.new(@path).messages
  end

  def test_drops_blank_and_non_conversational_messages
    session = Rubycog::Session.new(@path)
    session.save([{ 'role' => 'user', 'content' => 'keep' }, { 'role' => 'tool', 'content' => '{"x":1}' },
                  { 'role' => 'assistant', 'content' => '   ' }, { 'role' => 'assistant', 'content' => nil }])

    assert_equal [{ 'role' => 'user', 'content' => 'keep' }], session.messages
  end

  def test_merges_consecutive_assistant_messages
    session = Rubycog::Session.new(@path)
    session.save([{ 'role' => 'user', 'content' => 'q' },
                  { 'role' => 'assistant', 'content' => 'a1' },
                  { 'role' => 'assistant', 'content' => 'a2' },
                  { 'role' => 'user', 'content' => 'q2' }])

    assert_equal [{ 'role' => 'user', 'content' => 'q' },
                  { 'role' => 'assistant', 'content' => "a1\n\na2" },
                  { 'role' => 'user', 'content' => 'q2' }], session.messages
  end

  def test_keeps_only_the_most_recent_messages
    session = Rubycog::Session.new(@path)
    many = Array.new(Rubycog::Session::MAX_MESSAGES + 5) { |i| { 'role' => 'user', 'content' => i.to_s } }

    session.save(many)

    assert_equal Rubycog::Session::MAX_MESSAGES, session.messages.size
    assert_equal (Rubycog::Session::MAX_MESSAGES + 4).to_s, session.messages.last['content']
  end

  def test_clear_removes_the_file
    session = Rubycog::Session.new(@path)
    session.save([{ 'role' => 'user', 'content' => 'x' }])
    session.clear

    refute File.exist?(@path)
    assert_empty Rubycog::Session.new(@path).messages
  end

  def test_env_var_overrides_the_default_path
    path = Rubycog::Session.default_path(env: { 'RUBYCOG_SESSION' => '/tmp/custom.json' })

    assert_equal '/tmp/custom.json', path
  end
end
