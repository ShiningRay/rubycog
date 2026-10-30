# frozen_string_literal: true

require_relative 'test_helper'
require 'minitest/mock'
require 'tmpdir'

class AgentTest < Minitest::Test
  def test_streams_and_executes_an_approved_tool
    chat = FakeChat.new
    events = []
    agent = Rubycog::Agent.new(chat: chat)

    agent.ask('calculate') { |event| events << event }
    assert chat.awaiting_approval?
    agent.resolve(chat.pending_approvals.first, true)
    response = agent.complete { |event| events << event }
    RubyLLM.stub(:chat, FakeChat.new) { agent.reset }

    assert_equal 'The answer is 42.', response.content
    assert_equal ['calculate'], chat.questions
    assert_equal 1, chat.steps
    assert_equal({ name: 'eval', code: '6 * 7' },
      events.find { |event| event[:type] == :tool_call }[:payload])
    assert_equal '42', events.find { |event| event[:type] == :tool_result }[:payload]
    assert_equal ['I will calculate it.', 'The answer is 42.'],
      events.select { |event| event[:type] == :text }.map { |event| event[:payload] }
    assert_equal 2, events.count { |event| event[:type] == :text_end }
  end

  def test_denies_a_tool
    chat = FakeChat.new
    agent = Rubycog::Agent.new(chat: chat)
    agent.ask('calculate')
    agent.resolve(chat.pending_approvals.first, false)
    refute chat.awaiting_approval?
  end

  def test_reset_keeps_the_eval_context
    tool = Rubycog::EvalTool.new
    agent = Rubycog::Agent.new(chat: FakeChat.new, tool: tool)
    tool.execute(code: 'reuse_marker = 21')
    RubyLLM.stub(:chat, FakeChat.new) { agent.reset }

    assert_same tool, agent.instance_variable_get(:@tool)
    assert_equal '42', tool.execute(code: 'reuse_marker * 2')
  end

  def test_default_chat_receives_the_coding_workflow_instructions
    chat = FakeChat.new
    RubyLLM.stub(:chat, ->(**_options) { chat }) do
      Rubycog::Agent.new
    end

    assert_equal Rubycog::Agent::INSTRUCTIONS, chat.instructions
  end

  def test_restores_stored_turns_and_persists_each_step
    dir = Dir.mktmpdir
    path = File.join(dir, 'session.json')
    Rubycog::Session.new(path).save([{ 'role' => 'user', 'content' => 'earlier question' },
                                     { 'role' => 'assistant', 'content' => 'earlier answer' }])
    chat = FakeChat.new

    agent = Rubycog::Agent.new(chat: chat, session: Rubycog::Session.new(path))
    assert_equal %w[user assistant], chat.messages.map { |m| m[:role] }

    agent.ask('next question')
    stored = Rubycog::Session.new(path).messages

    assert_equal %w[earlier next], [stored.first['content'].split.first, stored[2]['content'].split.first]
    assert_equal 4, stored.size
  ensure
    FileUtils.remove_entry(dir)
  end

  def test_reset_forgets_the_stored_conversation
    dir = Dir.mktmpdir
    path = File.join(dir, 'session.json')
    Rubycog::Session.new(path).save([{ 'role' => 'user', 'content' => 'old' }])
    agent = Rubycog::Agent.new(chat: FakeChat.new, session: Rubycog::Session.new(path))

    RubyLLM.stub(:chat, FakeChat.new) { agent.reset }

    refute File.exist?(path)
  ensure
    FileUtils.remove_entry(dir)
  end

  def test_instructions_require_requirement_analysis_and_reuse_review
    instructions = Rubycog::Agent::INSTRUCTIONS

    assert_includes instructions, 'Before writing code'
    assert_includes instructions, 'review the code for reusable parts'
    assert_includes instructions, 'Keep one-off scripts inline'
    assert_includes instructions, 'add layers, factories'
    assert_includes instructions, 'survive restarts'
  end

  def test_reports_load_errors_instead_of_escaping_the_worker
    chat = FakeChat.new
    chat.define_singleton_method(:ask) { |_message, &_block| raise LoadError, 'missing' }
    agent = Rubycog::Agent.new(chat: chat)
    events = []

    assert_nil agent.ask('x') { |event| events << event }
    assert_equal 'LoadError: missing', events.find { |event| event[:type] == :error }[:payload]
  end

  def test_default_agent_registers_the_self_iteration_tools
    chat = FakeChat.new
    RubyLLM.stub(:chat, ->(**_options) { chat }) do
      Rubycog::Agent.new
    end

    assert_equal %w[eval read_source edit_source run_tests search_docs get_doc get_source learn_from_url save_experience search_experiences propose_evolution list_proposals approve_proposal run_evolution evolution_edit evolution_run_tests finish_evolution rollback_evolution suggest_proposals evolution_benchmark introspect_code], chat.tool_names
  end

  def test_compacts_a_long_history_before_asking_and_persists_the_summary
    dir = Dir.mktmpdir
    path = File.join(dir, 'session.json')
    long = Array.new(50) { |i| { role: i.even? ? 'user' : 'assistant', content: "turn #{i}" } }
    chat = FakeChat.new(messages: long)
    summarizer = AgentSummarizer.new('we did things')
    events = []
    agent = Rubycog::Agent.new(chat: chat, session: Rubycog::Session.new(path))

    RubyLLM.stub(:chat, summarizer) { agent.ask('next') { |event| events << event } }

    assert_equal ['next'], chat.questions
    assert(events.any? { |event| event[:type] == :status && event[:payload] == 'compacting context' })
    assert_includes chat.messages.first[:content], 'we did things'
    assert_equal Rubycog::Compactor::KEEP_TURNS + 2, chat.messages.size
    stored = Rubycog::Session.new(path).messages
    assert_includes stored.first['content'], 'we did things'
    refute(stored.any? { |message| message['content'] == 'turn 0' })
  ensure
    FileUtils.remove_entry(dir)
  end

  def test_manual_compact_leaves_a_short_history_alone
    chat = FakeChat.new(messages: [{ role: 'user', content: 'hi' }])
    agent = Rubycog::Agent.new(chat: chat)

    assert_nil agent.compact
    assert_equal [{ role: 'user', content: 'hi' }], chat.messages
  end

  def test_reset_eval_drops_persistent_locals
    tool = Rubycog::EvalTool.new
    agent = Rubycog::Agent.new(chat: FakeChat.new, tool: tool)
    tool.execute(code: 'agent_marker = 1')

    agent.reset_eval

    assert_equal 'false', tool.execute(code: 'defined?(agent_marker) ? true : false')
  end

  def test_isolated_eval_flag_reaches_the_default_tool
    agent = Rubycog::Agent.new(chat: FakeChat.new, isolated_eval: true)
    tool = agent.instance_variable_get(:@tools).find { |candidate| candidate.is_a?(Rubycog::EvalTool) }

    refute tool.keep_locals?
  end

  def test_compact_waits_for_an_open_tool_round
    chat = FakeChat.new
    agent = Rubycog::Agent.new(chat: chat)
    agent.ask('calculate')

    assert chat.awaiting_approval?
    assert_nil agent.compact
  end
end

# Returns a fixed summary so compaction runs without a network call.
class AgentSummarizer
  Response = Data.define(:content)

  def initialize(text)
    @text = text
  end

  def ask(_prompt)
    Response.new(content: @text)
  end
end
