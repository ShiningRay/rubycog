# frozen_string_literal: true

require 'ruby_llm'
require_relative '../evolution'
require_relative '../benchmark_runner'

module Rubycog
  # Run numeric benchmarks in BOTH the main checkout and the running
  # proposal's worktree, and report any regression. Call this before
  # finish_evolution to decide whether to set success=true. A regression
  # (worktree worse than main beyond tolerance) is a strong signal to call
  # finish_evolution with success=false or rollback_evolution.
  class EvolutionBenchmarkTool < RubyLLM::Tool
    def self.tool_name = 'evolution_benchmark'

    description <<~DESCRIPTION.strip
      Compare numeric benchmarks between the main checkout and the running
      proposal's worktree. Benchmarks are Ruby scripts under benchmarks/
      that print a number; higher is better unless a <name>.direction sidecar
      says "lower". Regressions beyond 5% are flagged. Use before
      finish_evolution to catch performance regressions.
    DESCRIPTION

    requires_approval

    def initialize(context:, runner: BenchmarkRunner.new)
      super()
      @context = context
      @runner = runner
    end

    def execute
      running = @context.current_running
      return 'evolution_benchmark error: no proposal is running' unless running

      wt_root = @context.worktree_root_for_running!
      main_root = @context.root

      comparison = @runner.compare(main_root: main_root, worktree_root: wt_root)
      body = @runner.format_comparison(comparison)
      verdict = if comparison[:results].empty?
                  'no common benchmarks found'
                elsif @runner.regressed?(comparison[:results])
                  'REGRESSION DETECTED — consider finish_evolution(success: false) or rollback_evolution'
                else
                  'no regression'
                end

      # Persist the comparison into the proposal so finish_evolution can see it.
      @context.proposals.attach_result(running['id'],
                                       'benchmark' => serialize(comparison),
                                       'benchmark_regressed' => @runner.regressed?(comparison[:results]))

      "benchmark comparison:\n#{body}\n\n#{verdict}"
    rescue Evolution::Error => e
      "evolution_benchmark error: #{e.message}"
    rescue StandardError => e
      "evolution_benchmark error: #{e.class}: #{e.message}"
    end

    private

    def serialize(comparison)
      {
        'results' => comparison[:results].map do |r|
          { 'name' => r.name, 'main' => r.main_score, 'worktree' => r.worktree_score,
            'regressed' => r.regressed, 'error' => r.error }
        end,
        'skipped' => comparison[:skipped]
      }
    end
  end
end
