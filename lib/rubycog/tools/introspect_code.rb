# frozen_string_literal: true

require 'ruby_llm'
require_relative '../introspection'

module Rubycog
  # Drive one self-introspection pass: run rubocop, reek, and the heuristic
  # scanner against RubyCog's own lib/, write a markdown report under
  # .rubycog/introspection/, and return a compact summary. The model is
  # expected to follow up by reading the worst files with read_source and
  # writing refactor or performance proposals.
  class IntrospectCodeTool < RubyLLM::Tool
    def self.tool_name = 'introspect_code'

    description <<~DESCRIPTION.strip
      Run static analysis (rubocop, reek) plus a structural heuristic scan
      (backup files, long methods/files, duplicate blocks, too many params,
      commented-out code) against RubyCog's lib/. Writes a markdown report
      under .rubycog/introspection/ and returns a compact summary. After
      calling, read the worst offenders with read_source, then write one or
      more propose_evolution entries with category=refactor (smell removal)
      or category=performance (speed/memory). The full report path is in
      the output for deeper inspection.
    DESCRIPTION

    parameter :paths, type: :array, required: false,
              description: 'Paths to scan (default lib/). Use sparingly to narrow scope.'

    def initialize(introspection: Introspection.new)
      super()
      @introspection = introspection
    end

    def execute(paths: nil)
      result = @introspection.run(paths: paths)
      top = top_offenders(result, limit: 10)
      <<~OUTPUT
        introspection complete
        report: #{result[:report_path]}

        #{result[:summary]}

        Top offenders (read these first):
        #{top}

        Next steps:
          1. read_source the files above to understand each smell
          2. propose_evolution with category=refactor for smell removal, or
             category=performance for speed/memory wins
          3. Existing benchmarks in benchmarks/ will catch perf regressions
      OUTPUT
    rescue StandardError => e
      "introspect_code error: #{e.class}: #{e.message}"
    end

    private

    # Pick up to `limit` findings across all sources, preferring errors and
    # high-severity rules. Falls back to file order when nothing stands out.
    def top_offenders(result, limit:)
      entries = []
      if result[:rubocop].ok?
        result[:rubocop].findings.each do |f|
          entries << "rubocop #{f}"
        end
      end
      if result[:reek].ok?
        result[:reek].findings.each { |f| entries << "reek #{f}" }
      end
      result[:heuristic].each { |f| entries << "heuristic #{f}" }

      return '(none)' if entries.empty?

      entries.first(limit).map { |e| "  #{e}" }.join("\n")
    end
  end
end
