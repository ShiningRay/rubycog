# frozen_string_literal: true

require 'fileutils'
require 'time'
require_relative 'static_analysis'
require_relative 'heuristic_scan'

module Rubycog
  # Combines StaticAnalysis (rubocop, reek) and HeuristicScan into a single
  # markdown report. Reports live under .rubycog/introspection/<stamp>.md so
  # successive introspections can be diffed. The most recent report path is
  # returned to the caller along with a compact summary suitable for an LLM.
  class Introspection
    DEFAULT_DIR = File.join(Rubycog.root, '.rubycog', 'introspection').freeze

    attr_reader :root, :dir, :static, :heuristic

    def initialize(root: Rubycog.root, dir: DEFAULT_DIR, static: nil, heuristic: nil)
      @root = root
      @dir = dir
      @static = static || StaticAnalysis.new(root: root)
      @heuristic = heuristic || HeuristicScan.new(root: root)
    end

    # Run everything and write a report. Returns
    # { report_path:, rubocop:, reek:, heuristic:, summary: }.
    def run(paths: nil)
      rubocop = static.rubocop(paths: paths)
      reek = static.reek(paths: paths)
      smells = heuristic.scan

      report_path = write_report(rubocop: rubocop, reek: reek, smells: smells)
      {
        report_path: report_path,
        rubocop: rubocop,
        reek: reek,
        heuristic: smells,
        summary: summarize(rubocop: rubocop, reek: reek, smells: smells)
      }
    end

    # Recent reports, newest first.
    def recent_reports(limit: 5)
      Dir.glob(File.join(dir, '*.md')).sort.reverse.first(limit)
    end

    private

    def summarize(rubocop:, reek:, smells:)
      lines = []
      lines << "rubocop: #{tool_summary(rubocop)}"
      lines << "reek: #{tool_summary(reek)}"
      lines << "heuristic: #{smells.size} findings"
      # Group heuristic findings by rule for the summary line.
      by_rule = smells.group_by(&:rule).transform_values(&:size)
      by_rule.each do |rule, count|
        lines << "  #{rule}: #{count}"
      end
      lines.join("\n")
    end

    def tool_summary(result)
      return "#{result.findings.size} findings" if result.ok?

      "error: #{result.error}"
    end

    def write_report(rubocop:, reek:, smells:)
      FileUtils.mkdir_p(dir)
      stamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
      path = File.join(dir, "#{stamp}.md")
      File.write(path, render_report(rubocop: rubocop, reek: reek, smells: smells, stamp: stamp))
      path
    end

    def render_report(rubocop:, reek:, smells:, stamp:)
      <<~MARKDOWN
        # Introspection report #{stamp}

        root: #{root}

        ## Summary

        #{summarize(rubocop: rubocop, reek: reek, smells: smells)}

        ## rubocop

        #{render_tool(rubocop)}

        ## reek

        #{render_tool(reek)}

        ## heuristic

        #{render_smells(smells)}
      MARKDOWN
    end

    def render_tool(result)
      return "error: #{result.error}" unless result.ok?
      return 'no findings' if result.findings.empty?

      by_file = result.findings.group_by(&:path)
      by_file.map do |path, findings|
        body = findings.map { |f| "- :#{f.line} [#{f.rule}] #{f.message}" }.join("\n")
        "### #{path}\n\n#{body}"
      end.join("\n\n")
    end

    def render_smells(smells)
      return 'no findings' if smells.empty?

      by_file = smells.group_by(&:path)
      by_file.map do |path, list|
        body = list.map { |f| "- :#{f.line} [#{f.rule}] #{f.message}" }.join("\n")
        "### #{path}\n\n#{body}"
      end.join("\n\n")
    end
  end
end
