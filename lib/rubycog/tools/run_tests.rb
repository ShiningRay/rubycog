# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'timeout'
require 'ruby_llm'
require_relative '../source_path'

module Rubycog
  # Runs a controlled test command from the project root. Paths are optional,
  # comma-separated test files under test/. With no paths it runs the full
  # suite through bundle exec rake test.
  class RunTestsTool < RubyLLM::Tool
    def self.tool_name = 'run_tests'

    description <<~DESCRIPTION.strip
      Run RubyCog tests. Pass comma-separated test files under test/, or leave
      paths empty to run the full suite. Output is capped and the exit status is
      reported. Use this after edit_source; never claim tests passed without
      this tool's output.
    DESCRIPTION

    parameter :paths, type: :string, required: false,
      description: 'Comma-separated test paths, for example test/agent_test.rb (empty = all)'

    requires_approval

    def initialize(self_iteration: nil, root: Rubycog.root, timeout: 120, command: nil)
      super()
      @self_iteration = self_iteration
      @root = root
      @timeout = timeout
      @command = command
    end

    def execute(paths: nil)
      files = parse_paths(paths)
      result = run(files)
      @self_iteration&.record_test(
        paths: files, ok: result[:ok], exit_status: result[:exit_status], output: result[:output]
      )
      "tests: exit=#{result[:exit_status] || 'timeout'} (#{result[:ok] ? 'passed' : 'failed'})\n#{result[:output]}"
    rescue ArgumentError => e
      "run_tests error: #{e.message}"
    end

    private

    def parse_paths(paths)
      return [] if paths.nil?

      list = paths.is_a?(Array) ? paths : paths.to_s.split(/[,\s]+/)
      list.reject { |path| path.to_s.strip.empty? }.map do |path|
        _full, relative = SourcePath.resolve(path.to_s, root: @root)
        unless relative.start_with?('test/')
          raise ArgumentError, "test path must be under test/: #{relative}"
        end

        relative
      end
    end

    def command_for(files)
      if @command
        return files.empty? ? @command : [*@command, *files]
      end

      if files.empty?
        ['bundle', 'exec', 'rake', 'test']
      else
        ['bundle', 'exec', 'ruby', '-Itest', *files]
      end
    end

    def run(files)
      output = +''
      error = +''
      status = nil

      Open3.popen3(*command_for(files), chdir: @root, pgroup: true) do |stdin, stdout, stderr, wait|
        stdin.close
        readers = [
          Thread.new { output << stdout.read },
          Thread.new { error << stderr.read }
        ]
        begin
          status = Timeout.timeout(@timeout) { wait.value }
        rescue Timeout::Error
          Process.kill('TERM', -wait.pid)
          status = wait.value
          return { ok: false, exit_status: nil,
                   output: trim("timeout after #{@timeout}s\n#{output}\n#{error}") }
        ensure
          readers.each { |reader| reader.join(1) }
        end
      end

      { ok: status&.success? || false, exit_status: status&.exitstatus,
        output: trim([output, error].reject(&:empty?).join("\n")) }
    rescue SystemCallError => e
      { ok: false, exit_status: nil, output: "#{e.class}: #{e.message}" }
    end

    def trim(text)
      value = text.to_s
      value.length > 4_000 ? "#{value[0, 4_000]}\n… (truncated)" : value
    end
  end
end
