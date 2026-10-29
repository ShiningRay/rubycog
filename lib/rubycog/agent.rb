# frozen_string_literal: true

require 'ruby_llm'
require_relative 'eval_tool'

module Rubycog
  class Agent
    INSTRUCTIONS = <<~TEXT.freeze
      You are a concise Ruby coding agent. You have eval, read_source,
      edit_source, and run_tests. eval runs unrestricted Ruby on the user's
      computer after approval; read_source and edit_source are restricted to
      RubyCog's own project files. Use them when executing or changing code is
      useful. Never claim code was executed or a test passed unless the tool
      returned it. Explain important side effects before requesting a tool call.

      Workflow:
      1. Before writing code, state the goal in one or two sentences. Name the
         inputs, outputs, and constraints you can infer, plus any assumption
         that could change the result. Ask only when the answer would change
         the implementation.
      2. Build the smallest complete solution. Run it with eval and check the
         result; when it is cheap, also check one boundary or failure case.
      3. After it works, review the code for reusable parts. Extract a method,
         class, or module when the logic repeats, the user asked for a
         reusable component, or the boundary is stable with a small interface
         that will clearly be needed again. Keep one-off scripts inline. Do
         not add layers, factories, or indirection without a concrete second
         use.
      4. When you extract something, give it a clear name, keep it small, and
         say in one sentence what is reusable and where it lives. Definitions
         made through eval last for the current process; if a part must
         survive restarts, propose a file and wait for approval.
      5. To change RubyCog itself, use read_source and edit_source, not raw
         eval file writes. Run run_tests after every edit and report failures.
         A running process keeps the old classes: say a restart is required,
         never claim the edit is active, and verify in a fresh process after
         /restart.
      6. Do not invent requirements, dependencies, or abstractions. Prefer
         plain Ruby over a new framework.
    TEXT

    PROVIDERS = %w[
      openai anthropic gemini deepseek openrouter mistral perplexity xai
    ].freeze

    DEFAULT_MODEL = 'deepseek-flash'

    attr_reader :chat, :model

    def self.configure(env: ENV)
      RubyLLM.configure do |config|
        PROVIDERS.each do |provider|
          key = env["#{provider.upcase}_API_KEY"]
          config.public_send("#{provider}_api_key=", key) if present?(key)
        end

        %w[openai anthropic gemini ollama openrouter].each do |provider|
          base = env["#{provider.upcase}_API_BASE"]
          config.public_send("#{provider}_api_base=", base) if present?(base)
        end

        config.default_model = if present?(env['RUBYCOG_MODEL'])
                                 env['RUBYCOG_MODEL']
                               else
                                 DEFAULT_MODEL
                               end
      end
    end

    def self.present?(value)
      !value.to_s.strip.empty?
    end

    def initialize(model: nil, chat: nil, tool: nil, tools: nil, session: nil, self_iteration: nil,
                   compactor: nil)
      @model = model
      @tool = tool
      @self_iteration = self_iteration
      @tools = tools || (tool ? [tool] : default_tools)
      @session = session
      @compactor = compactor || Compactor.new(model: model)
      @chat = chat || build_chat
      @session&.restore(@chat)
    end

    # Starts a fresh conversation and forgets the stored history.
    def reset
      @session&.clear
      @chat = build_chat
    end

    def ask(message, &on_event)
      run_step(on_event) do
        auto_compact
        @chat.ask(message, &stream)
      end
    end

    # Replaces a long history with a model-written summary. Returns the summary,
    # or nil when there was nothing to compact or a tool round is still open.
    def compact(&on_event)
      return nil unless @chat.complete?

      run_step(on_event) do
        emit(:status, 'compacting context')
        @compactor.compact(@chat)
      end
    end

    def complete(&on_event)
      run_step(on_event) { @chat.complete(&stream) }
    end

    def resolve(call, approved)
      approved ? @chat.approve(call) : @chat.deny(call)
    end

    def cancel
      @chat.cancel
    end

    private

    def run_step(on_event)
      @on_event = on_event
      @stream_open = false
      configure_callbacks if @chat != @configured_chat
      emit(:status, 'thinking')
      yield
    rescue Interrupt
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      emit(:error, "#{e.class}: #{e.message}")
      nil
    ensure
      emit(:text_end, nil) if @stream_open
      emit(:status, @chat.awaiting_approval? ? 'waiting for approval' : 'ready')
      persist
    end

    # Compaction runs before a user turn, never in the middle of a tool round,
    # and a failed summary must not cost the user their question.
    def auto_compact
      return unless @chat.respond_to?(:messages) && @compactor.needed?(@chat.messages)

      emit(:status, 'compacting context')
      @compactor.compact(@chat)
    rescue StandardError => e
      emit(:error, "compaction skipped: #{e.class}: #{e.message}")
    end

    # Saves the conversation after every step so a crash loses at most one reply.
    def persist
      return unless @session && @chat.respond_to?(:messages)

      @session.save(@chat.messages)
    end

    def build_chat
      RubyLLM.chat(model: @model).with_instructions(INSTRUCTIONS).with_tools(*@tools)
    end

    def default_tools
      [
        EvalTool.new,
        ReadSourceTool.new,
        EditSourceTool.new(self_iteration: @self_iteration),
        RunTestsTool.new(self_iteration: @self_iteration)
      ]
    end

    def configure_callbacks
      @configured_chat = @chat
      @chat.before_tool_call do |call|
        if @stream_open
          emit(:text_end, nil)
          @stream_open = false
        end
        emit(:status, "running #{call.name}")
        emit(:tool_call, { name: call.name, code: ToolPreview.for(call) })
      end

      @chat.after_tool_result do |result|
        emit(:tool_result, result.respond_to?(:content) ? result.content : result.to_s)
        emit(:status, 'thinking')
      end
    end

    def stream
      lambda do |chunk|
        content = chunk.content
        next if content.nil? || content.empty?

        @stream_open = true
        emit(:text, content)
      end
    end

    def emit(type, payload)
      @on_event&.call(type: type, payload: payload)
    end
  end
end
