# frozen_string_literal: true

require 'open3'
require 'json'
require 'timeout'

module Rubycog
  # Wraps rubocop and reek so the introspection tool can produce a unified
  # smell report. Both tools are invoked through `bundle exec` in the project
  # root with hard timeouts. Output is parsed from JSON for stable structure.
  # If a tool is not installed or fails, that section of the report is marked
  # with an error instead of raising.
  class StaticAnalysis
    TOOL_TIMEOUT = 60

    Result = Data.define(:tool, :ok, :findings, :error) do
      def ok? = ok
    end

    Finding = Data.define(:path, :line, :rule, :message, :severity) do
      def to_s
        "#{path}:#{line} [#{rule}] #{message}"
      end
    end

    attr_reader :root

    def initialize(root: Rubycog.root)
      @root = root
    end

    def rubocop(paths: nil)
      args = %w[exec rubocop --format json --force-exclusion]
      args.concat(paths || ['lib/'])
      run_tool('rubocop', args) do |json|
        parse_rubocop(json)
      end
    end

    def reek(paths: nil)
      args = %w[exec reek --format json --no-color]
      args.concat(paths || ['lib/'])
      run_tool('reek', args) do |json|
        parse_reek(json)
      end
    end

    private

    def run_tool(name, args)
      output = +''
      error = +''
      status = nil
      begin
        Open3.popen3('bundle', *args, chdir: root) do |stdin, stdout, stderr, wait|
          stdin.close
          readers = [
            Thread.new { output << stdout.read },
            Thread.new { error << stderr.read }
          ]
          begin
            status = Timeout.timeout(TOOL_TIMEOUT) { wait.value }
          rescue Timeout::Error
            Process.kill('TERM', wait.pid) rescue nil
            status = wait.value
            return Result.new(tool: name, ok: false, findings: [],
                              error: "timeout after #{TOOL_TIMEOUT}s")
          ensure
            readers.each { |r| r.join(1) }
          end
        end
      rescue SystemCallError => e
        return Result.new(tool: name, ok: false, findings: [],
                          error: "#{e.class}: #{e.message}")
      end

      # rubocop exits 1 when offenses are present; reek exits 2 on smells.
      # Both still emit parseable JSON on stdout in those cases.
      if output.strip.empty?
        return Result.new(tool: name, ok: false, findings: [],
                          error: "no output (exit=#{status&.exitstatus}): #{error.strip[0, 200]}")
      end

      begin
        findings = yield(output)
        Result.new(tool: name, ok: true, findings: findings, error: nil)
      rescue StandardError => e
        Result.new(tool: name, ok: false, findings: [],
                   error: "parse error: #{e.class}: #{e.message}; first 200 chars: #{output[0, 200]}")
      end
    end

    def parse_rubocop(json_text)
      data = JSON.parse(json_text)
      findings = []
      (data['files'] || []).each do |file|
        path = file['path']
        (file['offenses'] || []).each do |offense|
          findings << Finding.new(
            path: path,
            line: offense.dig('location', 'start_line') || offense.dig('location', 'line') || 0,
            rule: offense['cop_name'].to_s,
            message: offense['message'].to_s,
            severity: offense['severity'].to_s
          )
        end
      end
      findings
    end

    def parse_reek(json_text)
      data = JSON.parse(json_text)
      data.map do |entry|
        lines = entry['lines'] || [0]
        Finding.new(
          path: entry['source'].to_s,
          line: lines.first.to_i,
          rule: entry['smell_type'].to_s,
          message: entry['message'].to_s,
          severity: 'smell'
        )
      end
    end
  end
end
