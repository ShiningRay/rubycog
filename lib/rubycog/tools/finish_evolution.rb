# frozen_string_literal: true

require 'ruby_llm'
require_relative '../evolution'

module Rubycog
  # Mark the running proposal as evaluated (success) or failed. Captures diff
  # stats so the user can review before merging the branch.
  class FinishEvolutionTool < RubyLLM::Tool
    def self.tool_name = 'finish_evolution'

    description <<~DESCRIPTION.strip
      Finish the currently running proposal. If tests passed, marks it
      'evaluated' and records diff stats; otherwise marks it 'failed' with
      the given error. After evaluation the user can merge branch evo/<id>
      or call rollback_evolution to discard the worktree.
    DESCRIPTION

    parameter :notes, type: :string, description: 'What was changed and the test outcome'
    parameter :success, type: :boolean, description: 'true if tests passed and the change is ready'
    parameter :force, type: :boolean, required: false,
              description: 'Set true to mark evaluated even if evolution_benchmark detected a regression.'

    requires_approval

    def initialize(context:)
      super()
      @context = context
    end

    def execute(notes:, success:, force: false)
      running = @context.current_running
      return 'finish_evolution error: no proposal is running' unless running

      id = running['id']
      if success
        # Category-specific benchmark policy:
        #   feature     — regression requires force
        #   refactor    — regression is allowed (recorded for review)
        #   performance — regression blocks success outright (no force override)
        category = running['category'] || 'feature'
        regressed = running.dig('result', 'benchmark_regressed')
        case category
        when 'performance'
          if regressed
            return "finish_evolution error: performance proposal must not regress benchmarks. " \
                   "Call evolution_benchmark to see details, then either finish_evolution(success: false) " \
                   "or rollback_evolution. (force is not allowed for performance proposals.)"
          end
          # Additionally require that a benchmark was actually run.
          unless running.dig('result', 'benchmark')
            return 'finish_evolution error: performance proposal requires evolution_benchmark to be run first.'
          end
        when 'refactor'
          # allowed; just record the regression state in the evaluation notes
        else # feature
          if regressed && !force
            return "finish_evolution error: benchmark regression detected. Call evolution_benchmark to see details, " \
                   "then either finish_evolution(success: false), rollback_evolution, or " \
                   "finish_evolution(success: true, force: true) to override."
          end
        end

        stats = begin
          @context.diff_stats_for_running!
        rescue StandardError => e
          "diff stats unavailable: #{e.message}"
        end
        entry = @context.mark_evaluated!(id, notes: notes)
        merge_branch = entry.dig('result', 'branch')
        wt_path = entry.dig('result', 'worktree_path')
        forced_note = regressed && force && category == 'feature' ? ' (forced despite regression)' : ''
        refactor_note = regressed && category == 'refactor' ? ' (refactor: regression allowed)' : ''
        <<~OUTPUT
          evaluated proposal #{id}
          category: #{category}
          branch: #{merge_branch}
          worktree: #{wt_path}
          notes: #{notes}#{forced_note}#{refactor_note}

          diff stats:
          #{stats}

          To merge: git -C #{@context.root} merge #{merge_branch}
          To discard: rollback_evolution(id=#{id.inspect})
        OUTPUT
      else
        @context.mark_failed!(id, notes)
        "failed proposal #{id}\nerror: #{notes}\n(worktree preserved for inspection; use rollback_evolution to clean up)"
      end
    rescue Evolution::Error, ArgumentError => e
      "finish_evolution error: #{e.message}"
    rescue StandardError => e
      "finish_evolution error: #{e.class}: #{e.message}"
    end
  end
end
