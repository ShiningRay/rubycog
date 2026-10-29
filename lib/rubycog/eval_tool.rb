# frozen_string_literal: true

require 'ruby_llm'

module Rubycog
  # Deliberately executes unrestricted Ruby. The UI asks before every call
  # unless yolo mode is enabled.
  class EvalTool < RubyLLM::Tool
    def self.tool_name = 'eval'

    description <<~DESCRIPTION.strip
      Execute Ruby code in the agent's persistent local process. Use this for
      calculations and Ruby tasks that require execution. The code runs with
      the user's full permissions; this is not a sandbox. Return the value's
      inspection or the Ruby exception as text. Local variables persist across calls.
    DESCRIPTION

    parameter :code, type: :string,
      description: 'Complete Ruby source code to evaluate'

    requires_approval

    # The model's JSON arguments arrive with String keys; accept Symbols too.
    def self.code_from(call)
      arguments = call.arguments
      (arguments['code'] || arguments[:code]).to_s
    end

    def initialize(binding: TOPLEVEL_BINDING.dup, base_dir: nil)
      super()
      @binding = binding
      @base_dir = base_dir
    end

    def execute(code:)
      @binding.eval(code, eval_file, 1).inspect
    rescue Interrupt
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      "#{e.class}: #{e.message}"
    end

    private

    # A real filename gives require_relative a base path. With the default
    # eval filename it raises "cannot infer basepath".
    def eval_file
      File.join(@base_dir || Dir.pwd, '(eval)')
    end
  end
end
