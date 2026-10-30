# frozen_string_literal: true

require_relative 'proposal'
require_relative 'worktree'
require_relative 'source_edit'
require_relative 'source_path'
require_relative 'tools/run_tests'

module Rubycog
  # Runs an approved Proposal inside a fresh git worktree, then evaluates the
  # result. The executor does not use the LLM — it performs the work the model
  # has already described in the proposal's `touches` + `test_plan` and uses
  # the same SourceEdit/RunTestsTool primitives as interactive self-iteration.
  #
  # In v1 the executor only knows how to:
  #   1. create a worktree
  #   2. let the model edit files inside that worktree (via evolution_edit tool)
  #   3. run tests inside the worktree
  #   4. capture diff stats
  #   5. mark the proposal evaluated or failed
  #
  # The model is responsible for driving edits through the evolution_edit tool
  # while a proposal is in 'running' state. This keeps the LLM in the loop
  # without granting it raw file access to the main checkout.
  module Evolution
    class Error < StandardError; end

    # Bundles the store + worktree + project root so the tools share one
    # configuration. Agent owns one instance and passes it to every
    # evolution_* tool.
    class Context
      attr_reader :proposals, :worktree, :root, :self_iteration

      def initialize(root: Rubycog.root, proposals: nil, worktree: nil, self_iteration: nil)
        @root = root
        @proposals = proposals || Proposal.new
        @worktree = worktree || Worktree.new(root: root)
        @self_iteration = self_iteration
      end

      # The proposal currently being executed (status == 'running'). There is
      # at most one at a time; the executor refuses to start a second.
      def current_running
        proposals.list(status: 'running').first
      end

      def start!(id)
        raise Error, "another proposal is already running: #{current_running['id']}" if current_running

        proposal = proposals.find(id)
        raise Error, "proposal not found: #{id}" unless proposal
        raise Error, "proposal #{id} is #{proposal['status']}, expected approved" unless proposal['status'] == 'approved'

        path = worktree.create(id)
        proposals.transition(id, 'running', result: {
                               'worktree_path' => path,
                               'branch' => worktree.branch_for(id),
                               'started_at' => Time.now.utc.iso8601
                             })
      end

      def worktree_root_for_running!
        running = current_running
        raise Error, 'no proposal is running' unless running

        path = running.dig('result', 'worktree_path')
        raise Error, "running proposal #{running['id']} has no worktree_path" unless path && File.directory?(path)

        path
      end

      # Run the test suite inside the running worktree. Reuses RunTestsTool
      # so output format / caps stay consistent.
      def run_tests_in_worktree!(paths: nil)
        wt_root = worktree_root_for_running!
        runner = RunTestsTool.new(root: wt_root, self_iteration: nil)
        output = runner.execute(paths: paths)
        ok = output.start_with?('tests: exit=0')
        { ok: ok, output: output }
      end

      # Capture diff stats vs. the merge base for the running worktree.
      def diff_stats_for_running!
        running = current_running
        raise Error, 'no proposal is running' unless running

        result = worktree.inside(running['id'], 'diff', '--stat', 'HEAD')
        result.stdout.strip
      end

      def mark_evaluated!(id, notes:)
        proposals.transition(id, 'evaluated', result: { 'evaluation' => notes,
                                                        'evaluated_at' => Time.now.utc.iso8601 })
      end

      def mark_failed!(id, error)
        proposals.transition(id, 'failed', result: { 'error' => error.to_s })
      end

      # Cleanup a worktree without changing proposal state. Used by rollback
      # and by failed runs.
      def cleanup_worktree!(id)
        worktree.remove(id)
      end

      # -- budget enforcement -------------------------------------------------

      # Files (relative paths) changed so far in the running worktree, vs the
      # base commit. Computed from `git diff --name-only HEAD` so untracked
      # files created by evolution_edit are also counted.
      def changed_files_for_running!
        running = current_running
        raise Error, 'no proposal is running' unless running

        diff = worktree.inside(running['id'], 'diff', '--name-only', 'HEAD').stdout
        # `git diff` does not list untracked files; ls-files picks those up.
        untracked = worktree.inside(running['id'], 'ls-files', '--others', '--exclude-standard').stdout
        (diff.split("\n") + untracked.split("\n")).map(&:strip).reject(&:empty?).uniq
      end

      # Lines added+removed across the running worktree vs HEAD.
      def changed_lines_for_running!
        running = current_running
        raise Error, 'no proposal is running' unless running

        # --numstat prints "<added>\t<removed>\t<path>" per file. Binary files
        # print "-" for both columns; treat as zero.
        result = worktree.inside(running['id'], 'diff', '--numstat', 'HEAD').stdout
        result.split("\n").sum do |line|
          added, removed, = line.split("\t", 3)
          added.to_i + removed.to_i
        end
      end

      # Raise Evolution::Error if applying `additional_lines` to `path` would
      # exceed the running proposal's budget. Budget fields live under
      # proposal['budget'] with keys max_files / max_lines; either may be nil
      # to skip that check.
      def check_budget!(path, additional_lines:)
        running = current_running
        raise Error, 'no proposal is running' unless running

        budget = running['budget'] || {}
        max_files = budget['max_files']
        max_lines = budget['max_lines']

        if max_files
          files = changed_files_for_running!
          files = files | [path] if path
          if files.size > max_files
            raise Error, "budget exceeded: #{files.size} files > max_files=#{max_files} (#{files.join(', ')})"
          end
        end

        return unless max_lines

        total = changed_lines_for_running! + additional_lines.to_i
        return unless total > max_lines

        raise Error, "budget exceeded: #{total} lines > max_lines=#{max_lines} (current=#{changed_lines_for_running!}, this edit=#{additional_lines})"
      end
    end
  end
end
