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

  def test_records_when_each_turn_was_written
    at = Time.utc(2024, 5, 3, 12, 0, 0)
    session = Rubycog::Session.new(@path)
    session.save([{ 'role' => 'user', 'content' => 'q' }, { 'role' => 'assistant', 'content' => 'a' }],
                 stamps: [{ role: :user, text: 'q', at: at }, { role: :assistant, text: 'a', at: at + 5 }])

    assert_equal %w[2024-05-03T12:00:00Z 2024-05-03T12:00:05Z], session.messages.map { |message| message['at'] }
  end

  def test_merged_assistant_turn_keeps_the_time_of_its_first_message
    at = Time.utc(2024, 5, 3, 12, 0, 0)
    session = Rubycog::Session.new(@path)
    session.save([{ 'role' => 'user', 'content' => 'q' },
                  { 'role' => 'assistant', 'content' => 'a1' },
                  { 'role' => 'assistant', 'content' => 'a2' }],
                 stamps: [{ role: :user, text: 'q', at: at },
                          { role: :assistant, text: 'a1', at: at + 2 },
                          { role: :assistant, text: 'a2', at: at + 9 }])

    assert_equal "a1\n\na2", session.messages.last['content']
    assert_equal '2024-05-03T12:00:02Z', session.messages.last['at']
  end

  # Compaction rewrites the chat, so a briefing sits in front of turns the
  # screen still shows; matching has to resume at the first kept turn.
  def test_turns_missing_from_the_screen_stay_untimed_and_later_ones_still_match
    at = Time.utc(2024, 5, 3, 12, 0, 0)
    session = Rubycog::Session.new(@path)
    session.save([{ 'role' => 'user', 'content' => 'Compacted summary of the earlier conversation: x' },
                  { 'role' => 'user', 'content' => 'kept question' },
                  { 'role' => 'assistant', 'content' => 'kept answer' }],
                 stamps: [{ role: :user, text: 'lost question', at: at },
                          { role: :user, text: 'kept question', at: at + 60 },
                          { role: :assistant, text: 'kept answer', at: at + 62 }])

    refute session.messages.first.key?('at')
    assert_equal %w[2024-05-03T12:01:00Z 2024-05-03T12:01:02Z], session.messages.drop(1).map { |m| m['at'] }
  end

  def test_resaving_a_reloaded_session_keeps_the_timestamps
    at = Time.utc(2024, 5, 3, 12, 0, 0)
    Rubycog::Session.new(@path).save([{ 'role' => 'user', 'content' => 'q' }],
                                     stamps: [{ role: :user, text: 'q', at: at }])

    Rubycog::Session.new(@path).save(Rubycog::Session.new(@path).messages)

    assert_equal '2024-05-03T12:00:00Z', Rubycog::Session.new(@path).messages.first['at']
  end

  def test_ignores_an_unreadable_timestamp_in_the_file
    File.write(@path, JSON.generate('messages' => [{ 'role' => 'user', 'content' => 'q', 'at' => 'whenever' }]))

    assert_equal [{ 'role' => 'user', 'content' => 'q' }], Rubycog::Session.new(@path).messages
  end
end
