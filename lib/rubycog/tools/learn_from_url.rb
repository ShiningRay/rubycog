# frozen_string_literal: true

require 'ruby_llm'
require_relative '../experience'
require_relative '../web_fetcher'

module Rubycog
  # Fetch an external URL, return its readable text to the model, and offer to
  # persist a distilled experience. The tool only fetches and returns content;
  # the model decides what is worth keeping and calls save_experience itself.
  class LearnFromUrlTool < RubyLLM::Tool
    def self.tool_name = 'learn_from_url'

    description <<~DESCRIPTION.strip
      Fetch an external URL (blog post, GitHub README, docs page, paper) and
      return its readable text so you can extract reusable patterns. After
      reading, if the source contains a pattern worth keeping, call
      save_experience to record it. Use this when the user asks RubyCog to
      learn from another agent or source.
    DESCRIPTION

    parameter :url, type: :string, description: 'http(s) URL to fetch'

    def initialize(fetcher: WebFetcher)
      super()
      @fetcher = fetcher
    end

    def execute(url:)
      return 'learn_from_url error: url is required' if url.to_s.strip.empty?

      result = @fetcher.fetch(url)
      return "learn_from_url error: #{result.error}" unless result.ok?

      <<~OUTPUT
        URL: #{result.url}
        Status: #{result.status}
        Content-Type: #{result.content_type}
        Bytes: #{result.body.bytesize}

        --- content ---
        #{result.body}
        --- end ---

        If this source contains a reusable pattern for RubyCog, call save_experience
        with source=#{result.url.inspect}, a 1-2 sentence summary, and any patterns
        you extracted (name, idea, rubycog_fit).
      OUTPUT
    rescue StandardError => e
      "learn_from_url error: #{e.class}: #{e.message}"
    end
  end
end
