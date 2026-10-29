# frozen_string_literal: true

require_relative 'test_helper'
require 'minitest/mock'

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

  attr_reader :model, :questions, :steps

  def initialize
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

  def with_instructions(_instructions) = self
  def with_tools(_tool) = self

  def after_tool_result(&block)
    @callbacks[:after] << block
    self
  end

  def ask(question)
    @questions << question
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
    result = Struct.new(:content).new(@tool.execute(code: @call.arguments['code']))
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
end
