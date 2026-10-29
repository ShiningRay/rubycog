# frozen_string_literal: true

require_relative 'test_helper'
require 'minitest/mock'

# Stands in for the summarizer chat: records prompts, returns fixed content.
class FakeSummarizer
  Response = Data.define(:content)

  attr_reader :prompts

  def initialize(text)
    @text = text
    @prompts = []
  end

  def ask(prompt)
    @prompts << prompt
    Response.new(content: @text)
  end
end

# Minimal stand-in for RubyLLM::Chat: only history read and replace.
class FakeHistory
  attr_accessor :messages

  def initialize(messages)
    @messages = messages
  end
end

class CompactorTest < Minitest::Test
  def turns(count)
    Array.new(count) { |i| { 'role' => i.even? ? 'user' : 'assistant', 'content' => "turn #{i}" } }
  end

  def test_keeps_system_prompt_and_newest_turns
    system = { role: :system, content: 'SYS' }
    history = FakeHistory.new([system] + turns(20))
    summarizer = FakeSummarizer.new('- did stuff')
    summary = nil

    RubyLLM.stub(:chat, summarizer) { summary = Rubycog::Compactor.new.compact(history) }

    assert_equal '- did stuff', summary
    assert_equal 1 + Rubycog::Compactor::KEEP_TURNS, history.messages.length
    assert_equal :system, history.messages.first[:role]
    assert_includes history.messages[1][:content], '- did stuff'
    assert_includes history.messages[1][:content], 'turn 14'
    assert_equal 'turn 19', history.messages.last[:content]
    assert_equal %w[user assistant], history.messages[1..2].map { |message| message[:role] }
  end

  def test_briefing_stands_alone_when_the_next_kept_turn_is_from_the_assistant
    history = FakeHistory.new(turns(21)[1..])
    summarizer = FakeSummarizer.new('summary')

    RubyLLM.stub(:chat, summarizer) { Rubycog::Compactor.new.compact(history) }

    assert_equal 1 + Rubycog::Compactor::KEEP_TURNS, history.messages.length
    assert_includes history.messages.first[:content], 'summary'
    assert_equal 'turn 15', history.messages[1][:content]
  end

  def test_summarizes_only_the_older_turns
    history = FakeHistory.new(turns(20))
    summarizer = FakeSummarizer.new('summary')

    RubyLLM.stub(:chat, summarizer) { Rubycog::Compactor.new.compact(history) }

    prompt = summarizer.prompts.first
    assert_includes prompt, 'turn 13'
    refute_includes prompt, 'turn 14'
  end

  def test_leaves_a_short_history_alone
    original = turns(4)
    history = FakeHistory.new(original.dup)
    summarizer = FakeSummarizer.new('summary')

    summary = RubyLLM.stub(:chat, summarizer) { Rubycog::Compactor.new.compact(history) }

    assert_nil summary
    assert_equal original, history.messages
    assert_empty summarizer.prompts
  end

  def test_keeps_history_when_the_model_returns_nothing
    original = turns(20)
    history = FakeHistory.new(original.dup)

    summary = RubyLLM.stub(:chat, FakeSummarizer.new("  \n")) { Rubycog::Compactor.new.compact(history) }

    assert_nil summary
    assert_equal original, history.messages
  end

  def test_needed_tracks_turns_and_characters
    compactor = Rubycog::Compactor.new
    big = 'x' * (Rubycog::Compactor::MAX_CHARS + 1)

    refute compactor.needed?(turns(10))
    assert compactor.needed?(turns(Rubycog::Compactor::MAX_TURNS + 1))
    assert compactor.needed?([{ 'role' => 'user', 'content' => big }])
    assert compactor.needed?([{ 'role' => 'tool', 'content' => big }])
    refute compactor.needed?([{ role: 'system', content: big }])
  end
end
