# frozen_string_literal: true

# Stand-in model so header tests do not need a network or a real provider.
class FakeModel
  attr_reader :id

  def initialize(id = 'fake-model')
    @id = id
  end
end

# Scripted chat double: streams fixed text and "runs" the eval tool once, so
# the agent loop can be exercised without RubyLLM or a provider. Lives here
# rather than in one test file so any test can require it (test_helper does).
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

  def messages=(new_messages)
    @messages = new_messages
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
