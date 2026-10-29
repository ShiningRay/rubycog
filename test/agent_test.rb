# frozen_string_literal: true

require_relative 'test_helper'
require 'minitest/mock'
require 'tmpdir'

class FakeModel
  attr_reader :id

  def initialize(id = 'fake-model')
    @id = id
  end
end

class FakeChat
  Chunk = Data.define(:content)
  Response = Data.define(:content)
  ToolCall = Data.define(:id, :name, :arguments)

  attr_reader :model, :questions, :steps, :instructions, :messages, :tools

  def initialize(messages: [])
    @messages = messages
    @model = FakeModel.new
    @questions = []
    @steps = 0
    @callbacks = Hash.new { |hash, key| hash[key] = [] }
    @call = ToolCall.new(id: '1', name: 'eval', arguments: { 'code' => '6 * 7' })
    @tool = Rubycog::EvalTool.new
    @pending = false
  end

  def before_tool_call(&block)
    @callbacks[:before] << block
    self
  end

  def with_instructions(instructions)
    @instructions = instructions
    self
  end

  def with_tools(*tools)
    @tools = tools
    self
  end

  def tool_names = Array(@tools).map(&:name)

  def after_tool_result(&block)
    @callbacks[:after] << block
    self
  end

  def add_message(role:, content:)
    @messages << { role: role.to_s, content: content }
  end

  def ask(question)
    @questions << question
    @messages << { role: 'user', content: question }
    @messages << { role: 'assistant', content: 'I will calculate it.' }
    yield Chunk.new(content: 'I will calculate it.')
    @pending = true
    Response.new(content: nil)
  end

  def awaiting_approval? = @pending
  def complete? = !@pending
  def pending_approvals = [@call]
  def approve(_call) = @pending = false
  def deny(_call) = @pending = false
  def cancel = nil

  def complete
    @steps += 1
    @callbacks[:before].each { |callback| callback.call(@call) }
    # RubyLLM 2.1 passes the raw tool return value to after_tool_result.
    result = @tool.execute(code: @call.arguments['code'])
    @callbacks[:after].each { |callback| callback.call(result) }
    yield Chunk.new(content: 'The answer is 42.')
    Response.new(content: 'The answer is 42.')
  end
end

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

    assert_equal %w[eval read_source edit_source run_tests], chat.tool_names
  end
end
