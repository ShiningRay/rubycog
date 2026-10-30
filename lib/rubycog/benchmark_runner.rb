# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'timeout'
require 'yaml'

module Rubycog
  # Runs numeric benchmarks in two checkouts (typically main and a worktree)
  # and compares scores. A benchmark is any Ruby script under benchmarks/
  # that prints one or more `name<TAB>value` lines to stdout; higher is
  # better unless the script file's sidecar `.direction` says `lower`.
  #
  # Scripts are executed with the checkout as chdir, so they can require
  # lib/... relative to that checkout. Each script has a hard timeout.
  class BenchmarkRunner
    class Error < StandardError; end

    DEFAULT_DIR = 'benchmarks'
    SCRIPT_TIMEOUT = 30
    # Default regression threshold: fail if the score drops by more than 5%.
    DEFAULT_TOLERANCE = 0.05

    Result = Data.define(:name, :main_score, :worktree_score, :direction, :regressed, :error) do
      def ok? = error.nil?
      def delta
        return nil unless main_score && worktree_score

        worktree_score - main_score
      end

      def delta_pct
        return nil unless main_score && worktree_score && !main_score.zero?

        (worktree_score - main_score) / main_score.abs
      end
    end

    attr_reader :dir_name, :tolerance

    def initialize(dir_name: DEFAULT_DIR, tolerance: DEFAULT_TOLERANCE)
      @dir_name = dir_name
      @tolerance = tolerance
    end

    # Discover benchmark script paths under a checkout root. Sorted by name
    # so results are stable across runs.
    def scripts_under(root)
      dir = File.join(root, dir_name)
      return [] unless File.directory?(dir)

      Dir.glob(File.join(dir, '*.rb')).sort
    end

    # Run all scripts present in BOTH roots. Scripts that exist in only one
    # are skipped with a note in the return value's :skipped array.
    def compare(main_root:, worktree_root:)
      main_scripts = scripts_under(main_root).map { |p| File.basename(p) }
      wt_scripts = scripts_under(worktree_root).map { |p| File.basename(p) }
      common = main_scripts & wt_scripts
      skipped = (main_scripts | wt_scripts) - common

      results = common.map do |name|
        main_run = run_script(main_root, name)
        wt_run = run_script(worktree_root, name)
        build_result(name, main_run, wt_run)
      end

      { results: results, skipped: skipped }
    end

    # True when any result is a regression beyond the tolerance.
    def regressed?(results)
      results.any?(&:regressed)
    end

    def format_comparison(comparison)
      lines = []
      comparison[:results].each do |r|
        if r.error
          lines << "  #{r.name}: error=#{r.error}"
          next
        end
        delta = r.delta
        delta_pct = r.delta_pct
        marker = r.regressed ? ' REGRESSED' : ''
        lines << format('  %s: main=%.4f worktree=%.4f Δ=%.4f (%.2f%%)%s',
                        r.name, r.main_score, r.worktree_score,
                        delta, delta_pct ? delta_pct * 100 : 0.0, marker)
      end
      unless comparison[:skipped].empty?
        lines << "  skipped (present in only one checkout): #{comparison[:skipped].join(', ')}"
      end
      lines.empty? ? '  (no benchmarks)' : lines.join("\n")
    end

    private

    def run_script(root, name)
      path = File.join(root, dir_name, name)
      direction = read_direction(root, name)
      output = +''
      error = +''
      status = nil

      begin
        Open3.popen3(RbConfig.ruby, path, chdir: root) do |stdin, stdout, stderr, wait|
          stdin.close
          readers = [
            Thread.new { output << stdout.read },
            Thread.new { error << stderr.read }
          ]
          begin
            status = Timeout.timeout(SCRIPT_TIMEOUT) { wait.value }
          rescue Timeout::Error
            Process.kill('TERM', wait.pid) rescue nil
            status = wait.value
            return { score: nil, direction: direction, error: "timeout after #{SCRIPT_TIMEOUT}s" }
          ensure
            readers.each { |r| r.join(1) }
          end
        end
      rescue SystemCallError => e
        return { score: nil, direction: direction, error: "#{e.class}: #{e.message}" }
      end

      unless status&.success?
        return { score: nil, direction: direction,
                 error: "exit=#{status&.exitstatus}: #{error.strip[0, 200]}" }
      end

      score = parse_score(output)
      return { score: nil, direction: direction, error: "no numeric score in output: #{output.strip[0, 200]}" } unless score

      { score: score, direction: direction, error: nil }
    end

    # Scripts print `name<TAB>value` or just `value` (we take the last number).
    def parse_score(output)
      line = output.to_s.split("\n").map(&:strip).reject(&:empty?).last
      return nil unless line

      token = line.include?("\t") ? line.split("\t").last : line.split(/\s+/).last
      Float(token)
    rescue ArgumentError, TypeError
      nil
    end

    def read_direction(root, name)
      sidecar = File.join(root, dir_name, "#{name}.direction")
      return :higher unless File.exist?(sidecar)

      content = File.read(sidecar).strip.downcase
      content == 'lower' ? :lower : :higher
    rescue StandardError
      :higher
    end

    def build_result(name, main_run, wt_run)
      if main_run[:error]
        return Result.new(name: name, main_score: nil, worktree_score: nil,
                          direction: main_run[:direction], regressed: false,
                          error: "main: #{main_run[:error]}")
      end
      if wt_run[:error]
        return Result.new(name: name, main_score: main_run[:score], worktree_score: nil,
                          direction: main_run[:direction], regressed: false,
                          error: "worktree: #{wt_run[:error]}")
      end

      main_score = main_run[:score]
      wt_score = wt_run[:score]
      direction = main_run[:direction]
      regressed = regression?(main_score, wt_score, direction)
      Result.new(name: name, main_score: main_score, worktree_score: wt_score,
                 direction: direction, regressed: regressed, error: nil)
    end

    def regression?(main_score, wt_score, direction)
      return false if main_score.nil? || wt_score.nil?
      return false if main_score.zero? && wt_score.zero?

      case direction
      when :lower
        # lower is better; regression = worktree is bigger by > tolerance
        wt_score > main_score * (1 + tolerance)
      else
        # higher is better; regression = worktree is smaller by > tolerance
        wt_score < main_score * (1 - tolerance)
      end
    end
  end
end
