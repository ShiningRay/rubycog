# frozen_string_literal: true

require 'ruby_llm'
require_relative '../evolution'

module Rubycog
  # List proposals, optionally filtered by status. Empty filter lists all.
  class ListProposalsTool < RubyLLM::Tool
    def self.tool_name = 'list_proposals'

    description <<~DESCRIPTION.strip
      List RubyCog evolution proposals. Optional status filter:
      proposed | approved | running | evaluated | merged | rejected | failed | rolled_back.
      Use this to find proposals that need approval or have results to review.
    DESCRIPTION

    parameter :status, type: :string, required: false, description: 'Optional status filter'
    parameter :full, type: :boolean, required: false, description: 'Full text vs one-line'

    MAX_RESULTS = 20

    def initialize(context:)
      super()
      @context = context
    end

    def execute(status: nil, full: false)
      if status && !Proposal::STATES.include?(status)
        return "list_proposals error: unknown status #{status} (valid: #{Proposal::STATES.join(', ')})"
      end

      hits = @context.proposals.list(status: status)
      return "no proposals matched#{status ? " status=#{status}" : ''}" if hits.empty?

      shown = hits.first(MAX_RESULTS)
      body = if full
               shown.map { |e| Proposal.to_text(e) }.join("\n\n---\n\n")
             else
               shown.map { |e| Proposal.to_line(e) }.join("\n")
             end
      suffix = hits.size > MAX_RESULTS ? "\n(showing first #{MAX_RESULTS} of #{hits.size})" : "\n(#{hits.size} total)"
      body + suffix
    rescue StandardError => e
      "list_proposals error: #{e.class}: #{e.message}"
    end
  end
end
