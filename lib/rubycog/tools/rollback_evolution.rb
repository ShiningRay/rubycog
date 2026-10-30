# frozen_string_literal: true

require 'ruby_llm'
require_relative '../evolution'

module Rubycog
  # Discard a proposal's worktree and branch. Valid from evaluated or failed
  # states. The proposal itself is kept with status rolled_back for audit.
  class RollbackEvolutionTool < RubyLLM::Tool
    def self.tool_name = 'rollback_evolution'

    description <<~DESCRIPTION.strip
      Discard the worktree and branch for an evaluated or failed proposal.
      Moves the proposal to 'rolled_back'. Use when the change should not be
      merged.
    DESCRIPTION

    parameter :id, type: :string, description: 'Proposal id (evaluated or failed)'

    requires_approval

    def initialize(context:)
      super()
      @context = context
    end

    def execute(id:)
      proposal = @context.proposals.find(id)
      return "rollback_evolution error: proposal not found: #{id}" unless proposal
      unless %w[evaluated failed].include?(proposal['status'])
        return "rollback_evolution error: cannot rollback from #{proposal['status']} (must be evaluated or failed)"
      end

      @context.cleanup_worktree!(id)
      final = @context.proposals.transition(id, 'rolled_back')
      "rolled back #{id}\nworktree and branch removed\nstatus: #{final['status']}"
    rescue Evolution::Error, ArgumentError => e
      "rollback_evolution error: #{e.message}"
    rescue StandardError => e
      "rollback_evolution error: #{e.class}: #{e.message}"
    end
  end
end
