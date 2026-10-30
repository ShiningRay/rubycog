# frozen_string_literal: true

require 'ruby_llm'
require_relative '../evolution'
require_relative '../source_edit'
require_relative '../source_path'

module Rubycog
  # Edit a file inside the running proposal's worktree. Same mechanics as
  # edit_source (unique match, backups, syntax check, atomic write) but the
  # paths resolve against the worktree root, not the main checkout. This is
  # the only way the model can change code during an evolution run.
  class EvolutionEditTool < RubyLLM::Tool
    def self.tool_name = 'evolution_edit'

    description <<~DESCRIPTION.strip
      Edit a file inside the running proposal's worktree. Works exactly like
      edit_source but the path is relative to the worktree, not the main
      checkout. Requires a proposal in 'running' state (call run_evolution
      first).
    DESCRIPTION

    parameter :path, type: :string, description: 'Relative path, e.g. lib/rubycog/agent.rb'
    parameter :old_string, type: :string, required: false,
              description: 'Text to replace; must match exactly once. Empty for new files under test/ or docs/.'
    parameter :new_string, type: :string, description: 'Replacement text'
    parameter :reason, type: :string, required: false

    requires_approval

    def initialize(context:)
      super()
      @context = context
    end

    def execute(path:, new_string:, old_string: nil, reason: nil)
      wt_root = @context.worktree_root_for_running!
      full, relative = SourcePath.resolve(path, root: wt_root,
                                                must_exist: !old_string.to_s.empty?,
                                                write: true)
      # Plan first so we know the actual line delta before enforcing budget.
      plan = SourceEdit.plan(full, relative, old_string.to_s, new_string.to_s)
      delta = line_delta(plan[:original], plan[:updated])
      @context.check_budget!(relative, additional_lines: delta)

      backup_root = File.join(wt_root, '.rubycog', 'backups')
      result = SourceEdit.apply(full, relative, old_string.to_s, new_string.to_s,
                                reason: reason.to_s, backup_root: backup_root)
      return "evolution_edit error: #{result[:stage]}: #{result[:error]}" unless result[:ok]

      "edited #{relative} (Δ#{delta} lines)\n#{result[:diff]}"
    rescue Evolution::Error, ArgumentError => e
      "evolution_edit error: #{e.message}"
    rescue StandardError => e
      "evolution_edit error: #{e.class}: #{e.message}"
    end

    private

    # Total added+removed lines for a before/after pair. Used for budget.
    def line_delta(before, after)
      before_lines = before.to_s.lines
      after_lines = after.to_s.lines
      common = 0
      # Cheap approximation: count differing lines via LCS-ish comparison.
      # For budget purposes an overestimate is safer than an underestimate,
      # so we use max(before, after) - (lines that stayed identical).
      b = before_lines.dup
      a = after_lines.dup
      # Walk both with simple hash-count intersection.
      counts = Hash.new(0)
      b.each { |l| counts[l] += 1 }
      a.each { |l| counts[l] -= 1 }
      # Sum of absolute counts is the symmetric difference size.
      counts.values.sum(&:abs)
    end
  end
end
