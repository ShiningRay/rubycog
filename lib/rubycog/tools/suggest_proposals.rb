# frozen_string_literal: true

require 'ruby_llm'
require_relative '../evolution'
require_relative '../experience'

module Rubycog
  # Survey experiences that no proposal has referenced yet and surface them as
  # candidates for new proposals. The tool itself does not write proposals —
  # the model reads the list, picks the most promising, and calls
  # propose_evolution with experience_id set. This keeps "what should I work
  # on" explicit and auditable.
  class SuggestProposalsTool < RubyLLM::Tool
    def self.tool_name = 'suggest_proposals'

    description <<~DESCRIPTION.strip
      Suggest next-step proposals by listing experiences that no existing
      proposal references. Use this when the user asks RubyCog to set its own
      goals or when you want to decide what to improve next. After calling,
      pick the most promising experiences and call propose_evolution with
      experience_id. Empty result means every saved experience already has
      a proposal.
    DESCRIPTION

    parameter :limit, type: :integer, required: false,
              description: 'Max experiences to return (default 10)'

    MAX_LIMIT = 50

    def initialize(context:, experiences: Experience.new)
      super()
      @context = context
      @experiences = experiences
    end

    def execute(limit: 10)
      cap = [[limit.to_i, 1].max, MAX_LIMIT].min
      referenced = referenced_experience_ids
      candidates = @experiences.all.reject { |e| referenced.include?(e['id']) }

      if candidates.empty?
        total = @experiences.all.size
        return "no unreferenced experiences (#{total} total, all already linked to proposals)" if total.positive?

        return 'no experiences recorded yet — call learn_from_url + save_experience first'
      end

      shown = candidates.first(cap)
      body = shown.map do |e|
        <<~ENTRY
          #{e['id']} (#{e['confidence']}) [#{e['tags'].join(', ')}]
            summary: #{e['summary']}
            applicable_to: #{e['applicable_to'].join(', ')}
            source: #{e['source']}
        ENTRY
      end.join("\n")

      <<~OUTPUT
        #{candidates.size} unreferenced experiences (showing #{shown.size}):

        #{body}

        Next: pick the most promising and call propose_evolution with
        experience_id set to one of these ids.
      OUTPUT
    rescue StandardError => e
      "suggest_proposals error: #{e.class}: #{e.message}"
    end

    private

    def referenced_experience_ids
      @context.proposals.all.map { |p| p['experience_id'] }.compact.uniq
    end
  end
end
