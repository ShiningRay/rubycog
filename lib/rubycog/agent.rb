# frozen_string_literal: true

require 'ruby_llm'
require_relative 'eval_tool'

module Rubycog
  class Agent
    INSTRUCTIONS = <<~TEXT.freeze
      You are a concise Ruby coding agent. Your only tool is eval, which runs
      unrestricted Ruby on the user's computer after their explicit approval.
      Use it when executing Ruby is useful. Never claim code was executed or
      report a result unless the tool returned it. Explain important side
      effects before requesting a tool call.
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

    def initialize(model: nil, chat: nil, tool: EvalTool.new)
      @model = model
      @tool = tool
      @chat = chat || build_chat
    end

    def reset
      @chat = build_chat
    end

    def ask(message, &on_event)
      run_step(on_event) { @chat.ask(message, &stream) }
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
    rescue StandardError => e
      emit(:error, "#{e.class}: #{e.message}")
      nil
    ensure
      emit(:text_end, nil) if @stream_open
      emit(:status, @chat.awaiting_approval? ? 'waiting for approval' : 'ready')
    end

    def build_chat
      RubyLLM.chat(model: @model).with_instructions(INSTRUCTIONS).with_tools(@tool)
    end

    def configure_callbacks
      @configured_chat = @chat
      @chat.before_tool_call do |call|
        if @stream_open
          emit(:text_end, nil)
          @stream_open = false
        end
        emit(:status, 'running eval')
        emit(:tool_call, {
          name: call.name,
          code: call.arguments['code'] || call.arguments[:code].to_s
        })
      end

      @chat.after_tool_result do |result|
        emit(:tool_result, result.content)
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
