# frozen_string_literal: true

require 'ruby_llm'
require_relative '../experience'

module Rubycog
  # Persist a distilled experience extracted from an external source. The
  # calling model is responsible for the quality of the summary and patterns.
  class SaveExperienceTool < RubyLLM::Tool
    def self.tool_name = 'save_experience'

    description <<~DESCRIPTION.strip
      Save a reusable pattern learned from an external source into RubyCog's
      experience store. Use this after learn_from_url (or any reading) when
      you find an idea worth applying to RubyCog later. Duplicate source URLs
      are rejected.
    DESCRIPTION

    parameter :source, type: :string, description: 'Source URL (unique per experience)'
    parameter :summary, type: :string, description: '1-2 sentence summary of the reusable idea'
    parameter :tags, type: :array, required: false,
              description: 'Short tags for later search, e.g. ["agent","tools"]'
    parameter :applicable_to, type: :array, required: false,
              description: 'RubyCog areas this applies to, e.g. ["tool_design","instructions"]'
    parameter :patterns, type: :array, required: false,
              description: 'Array of {name, idea, rubycog_fit} hashes describing concrete patterns'
    parameter :confidence, type: :string, required: false,
              description: 'low | medium | high (default medium)'
    parameter :notes, type: :string, required: false, description: 'Optional free-form notes'

    def initialize(store: Experience.new)
      super()
      @store = store
    end

    def execute(source:, summary:, tags: [], applicable_to: [], patterns: [], confidence: 'medium', notes: nil)
      entry = @store.create(
        source: source, summary: summary, tags: tags || [],
        applicable_to: applicable_to || [], patterns: patterns || [],
        confidence: confidence || 'medium', notes: notes
      )
      "saved experience #{entry['id']}\n#{Experience.to_text(entry)}"
    rescue ArgumentError => e
      "save_experience error: #{e.message}"
    rescue StandardError => e
      "save_experience error: #{e.class}: #{e.message}"
    end
  end
end
