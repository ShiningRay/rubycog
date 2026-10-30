# frozen_string_literal: true

require 'ruby_llm'
require_relative '../experience'

module Rubycog
  # Search previously saved experiences. Query words are ANDed across summary,
  # tags, source, applicable_to, and pattern text. Empty query lists everything.
  class SearchExperiencesTool < RubyLLM::Tool
    def self.tool_name = 'search_experiences'

    description <<~DESCRIPTION.strip
      Search RubyCog's experience store for patterns previously learned from
      external sources. Use this BEFORE modifying RubyCog itself to recall how
      other agents solved a similar problem. Query words are ANDed,
      case-insensitive. Empty query lists all experiences.
    DESCRIPTION

    parameter :query, type: :string, required: false,
              description: 'Keywords (space-separated). Leave empty to list all.'
    parameter :full, type: :boolean, required: false,
              description: 'When true, return full text of each match (default one-line).'

    MAX_RESULTS = 10

    def initialize(store: Experience.new)
      super()
      @store = store
    end

    def execute(query: '', full: false)
      hits = @store.search(query.to_s)
      return "no experiences matched: #{query.to_s.strip}" if hits.empty?

      shown = hits.first(MAX_RESULTS)
      body = if full
               shown.map { |e| Experience.to_text(e) }.join("\n\n---\n\n")
             else
               shown.map { |e| Experience.to_line(e) }.join("\n")
             end
      suffix = hits.size > MAX_RESULTS ? "\n(showing first #{MAX_RESULTS} of #{hits.size})" : "\n(#{hits.size} matches)"
      body + suffix
    rescue StandardError => e
      "search_experiences error: #{e.class}: #{e.message}"
    end
  end
end
