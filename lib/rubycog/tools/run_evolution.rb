# frozen_string_literal: true

require 'ruby_llm'
require_relative '../evolution'

module Rubycog
  # Start an approved proposal: creates a worktree and moves state to running.
  # After this the model uses evolution_edit / evolution_run_tests to work
  # inside the worktree, then finish_evolution to record the outcome.
  class RunEvolutionTool < RubyLLM::Tool
    def self.tool_name = 'run_evolution'

    description <<~DESCRIPTION.strip
      Start an approved proposal. Creates an isolated git worktree under
      .rubycog/worktrees/<id> on branch evo/<id>. The proposal moves to
      'running'. Only one proposal can run at a time. After calling this,
      use evolution_edit to change files inside the worktree, then
      evolution_run_tests, then finish_evolution.
    DESCRIPTION

    parameter :id, type: :string, description: 'Proposal id (must be approved)'

    requires_approval

    def initialize(context:)
      super()
      @context = context
    end

    def execute(id:)
      entry = @context.start!(id)
      <<~OUTPUT
        started proposal #{id}
        worktree: #{entry.dig('result', 'worktree_path')}
        branch: #{entry.dig('result', 'branch')}

        Next steps:
          1. evolution_edit to change files (paths relative to the worktree)
          2. evolution_run_tests to verify
          3. finish_evolution with notes (success or failure)
      OUTPUT
    rescue Evolution::Error, ArgumentError => e
      "run_evolution error: #{e.message}"
    rescue StandardError => e
      "run_evolution error: #{e.class}: #{e.message}"
    end
  end
end
