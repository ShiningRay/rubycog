# frozen_string_literal: true

require 'ruby_llm'

module Rubycog
  # Deliberately executes unrestricted Ruby. The UI asks before every call.
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

    def initialize(binding: TOPLEVEL_BINDING.dup)
      super()
      @binding = binding
    end

    def execute(code:)
      @binding.eval(code).inspect
    rescue StandardError, SyntaxError => e
      "#{e.class}: #{e.message}"
    end
  end
end
