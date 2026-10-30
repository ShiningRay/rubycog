# frozen_string_literal: true

require 'ruby_llm'
require_relative '../evolution'

module Rubycog
  # Mark a proposed proposal as approved. The tool exists so the model can
  # drive the workflow end-to-end, but RubyLLM's approval gate still applies
  # (the human sees "approve_proposal" and must accept).
  class ApproveProposalTool < RubyLLM::Tool
    def self.tool_name = 'approve_proposal'

    description <<~DESCRIPTION.strip
      Approve a 'proposed' proposal so it can be executed. This does NOT run
      the change; it only moves the state to 'approved'. After approval, call
      run_evolution to start work in a worktree.
    DESCRIPTION

    parameter :id, type: :string, description: 'Proposal id'

    requires_approval

    def initialize(context:)
      super()
      @context = context
    end

    def execute(id:)
      entry = @context.proposals.transition(id, 'approved')
      "approved\n#{Proposal.to_text(entry)}"
    rescue ArgumentError => e
      "approve_proposal error: #{e.message}"
    rescue StandardError => e
      "approve_proposal error: #{e.class}: #{e.message}"
    end
  end
end
