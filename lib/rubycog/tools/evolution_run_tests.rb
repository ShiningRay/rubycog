# frozen_string_literal: true

require 'ruby_llm'
require_relative '../evolution'

module Rubycog
  # Run the test suite inside the running proposal's worktree.
  class EvolutionRunTestsTool < RubyLLM::Tool
    def self.tool_name = 'evolution_run_tests'

    description <<~DESCRIPTION.strip
      Run tests inside the running proposal's worktree. Equivalent to
      run_tests but chdir'd to the worktree. Use after evolution_edit to
      verify the change before finish_evolution.
    DESCRIPTION

    parameter :paths, type: :string, required: false,
              description: 'Comma-separated test paths relative to worktree (empty = full suite)'

    requires_approval

    def initialize(context:)
      super()
      @context = context
    end

    def execute(paths: nil)
      result = @context.run_tests_in_worktree!(paths: paths)
      result[:output]
    rescue Evolution::Error => e
      "evolution_run_tests error: #{e.message}"
    rescue StandardError => e
      "evolution_run_tests error: #{e.class}: #{e.message}"
    end
  end
end
