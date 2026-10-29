# frozen_string_literal: true

require 'ruby_llm'
require_relative '../source_docs'

module Rubycog
  # Searches documentation comments above classes, modules and methods.
  class SearchDocsTool < RubyLLM::Tool
    def self.tool_name = 'search_docs'

    description <<~DESCRIPTION.strip
      Search documentation comments in RubyCog and the current project. Query
      words are ANDed (space separated, case-insensitive); class names, method
      names, file paths and comments all participate. Use this to find where a
      capability lives before reading or editing code.
    DESCRIPTION

    parameter :query, type: :string, description: 'Keywords, space separated'

    def initialize(roots: nil)
      super()
      @roots = roots
    end

    def execute(query:)
      words = query.to_s.strip
      return 'search_docs error: query is required' if words.empty?

      hits = SourceDocs.search(words, roots: @roots || SourceDocs.roots)
      return "no source documentation matched: #{words}\ntry fewer or different keywords" if hits.empty?

      lines = hits.first(SourceDocs::MAX_RESULTS).map do |entry|
        "#{entry.label} (#{entry.file}:#{entry.line})\n  #{entry.comment[0, 160]}"
      end
      suffix = hits.size > SourceDocs::MAX_RESULTS ? " (showing first #{SourceDocs::MAX_RESULTS})" : ''
      "#{lines.join("\n")}\n(#{hits.size} matches#{suffix})"
    rescue StandardError => e
      "search_docs error: #{e.class}: #{e.message}"
    end
  end
end
