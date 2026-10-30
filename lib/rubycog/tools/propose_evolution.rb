# frozen_string_literal: true

require 'ruby_llm'
require_relative '../evolution'

module Rubycog
  # Write a new Proposal to disk. The proposal starts in 'proposed' state and
  # cannot be executed until a human approves it (via approve_proposal or by
  # editing the YAML). Always call this BEFORE changing RubyCog itself.
  class ProposeEvolutionTool < RubyLLM::Tool
    def self.tool_name = 'propose_evolution'

    description <<~DESCRIPTION.strip
      Create a proposal to change RubyCog itself. Required: title, motivation.
      Optionally link an experience_id, describe expected_benefit, risk,
      touches (file paths), test_plan, and budget (max_files / max_lines).
      The proposal starts as 'proposed'; a human must approve it before any
      code is changed. Use this whenever an experience suggests a real edit.
    DESCRIPTION

    parameter :title, type: :string, description: 'One-line summary of the change'
    parameter :motivation, type: :string, description: 'Why this change is worth making'
    parameter :category, type: :string, required: false,
              description: 'feature (default) | refactor | performance. refactor tolerates benchmark regressions (reviewer decides); performance requires benchmark improvement.'
    parameter :experience_id, type: :string, required: false, description: 'Related Experience id'
    parameter :expected_benefit, type: :string, required: false
    parameter :risk, type: :string, required: false
    parameter :touches, type: :array, required: false, description: 'Files expected to change'
    parameter :test_plan, type: :string, required: false
    parameter :budget, type: :object, required: false,
              description: 'Optional {"max_files":N,"max_lines":M}'

    def initialize(context:)
      super()
      @context = context
    end

    def execute(title:, motivation:, category: 'feature', experience_id: nil, expected_benefit: '',
                risk: '', touches: [], test_plan: '', budget: {})
      entry = @context.proposals.create(
        title: title, motivation: motivation, category: category,
        experience_id: experience_id, expected_benefit: expected_benefit,
        risk: risk, touches: touches || [], test_plan: test_plan,
        budget: budget || {}
      )
      "created proposal\n#{Proposal.to_text(entry)}"
    rescue ArgumentError => e
      "propose_evolution error: #{e.message}"
    rescue StandardError => e
      "propose_evolution error: #{e.class}: #{e.message}"
    end
  end
end
