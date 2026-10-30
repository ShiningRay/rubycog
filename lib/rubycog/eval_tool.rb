# frozen_string_literal: true

require 'ruby_llm'

# A top-level factory: each call returns a binding with its own local table
# and an anonymous Object as self. Defining it at file top level keeps the
# lexical cref at Object, so constants created by eval still land where a
# top-level eval would put them.
RUBYCOG_EVAL_BINDING_FACTORY = -> { Object.new.instance_eval { binding } }

module Rubycog
  # Deliberately executes unrestricted Ruby. The UI asks before every call
  # unless yolo mode is enabled.
  class EvalTool < RubyLLM::Tool
    def self.tool_name = 'eval'

    description <<~DESCRIPTION.strip
      Execute Ruby code in the agent's persistent local process. Use this for
      calculations and Ruby tasks that require execution. The code runs with
      the user's full permissions; this is not a sandbox. Return the value's
      inspection or the Ruby exception as text. Local variables persist across
      calls by default; the user can reset that context or run in isolated mode.
    DESCRIPTION

    parameter :code, type: :string,
      description: 'Complete Ruby source code to evaluate'

    requires_approval

    # The model's JSON arguments arrive with String keys; accept Symbols too.
    def self.code_from(call)
      arguments = call.arguments
      (arguments['code'] || arguments[:code]).to_s
    end

    def initialize(binding: nil, base_dir: nil, keep_locals: true)
      super()
      @keep_locals = keep_locals
      @binding = binding
      @binding ||= fresh_binding if @keep_locals
      @base_dir = base_dir
    end

    def keep_locals? = @keep_locals

    # Drops the local variable table. Constants, classes, globals, threads and
    # open resources created by eval are not removed; restart for those.
    def reset
      @binding = fresh_binding if @keep_locals
      self
    end

    def execute(code:)
      target = @keep_locals ? (@binding ||= fresh_binding) : fresh_binding
      target.eval(code, eval_file, 1).inspect
    rescue Interrupt
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      "#{e.class}: #{e.message}"
    end

    private

    def fresh_binding
      # Keep the traditional top-level self for the default session. Isolated
      # mode uses the file-top-level factory so each call gets a separate
      # anonymous object and local table.
      @keep_locals ? TOPLEVEL_BINDING.dup : RUBYCOG_EVAL_BINDING_FACTORY.call
    end

    # A real filename gives require_relative a base path. With the default
    # eval filename it raises "cannot infer basepath".
    def eval_file
      File.join(@base_dir || Dir.pwd, '(eval)')
    end
  end
end
