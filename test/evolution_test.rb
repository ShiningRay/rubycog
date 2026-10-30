# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'

class ProposalTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-prop')
    @store = Rubycog::Proposal.new(dir: @dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_create_initial_state
    entry = @store.create(title: 'Add retry', motivation: 'Network flakiness')
    assert_equal 'proposed', entry['status']
    assert entry['id'].start_with?('prop-add-retry')
    assert_equal Rubycog::Proposal::DEFAULT_BUDGET, entry['budget']
  end

  def test_create_requires_title_and_motivation
    assert_raises(ArgumentError) { @store.create(title: '', motivation: 'x') }
    assert_raises(ArgumentError) { @store.create(title: 'x', motivation: ' ') }
  end

  def test_create_accepts_budget_override
    entry = @store.create(title: 'X', motivation: 'Y', budget: { 'max_files' => 5, 'max_lines' => 200 })
    assert_equal 5, entry['budget']['max_files']
    assert_equal 200, entry['budget']['max_lines']
  end

  def test_transition_happy_path
    entry = @store.create(title: 'X', motivation: 'Y')
    @store.transition(entry['id'], 'approved')
    @store.transition(entry['id'], 'running')
    final = @store.transition(entry['id'], 'evaluated', result: { 'notes' => 'ok' })
    assert_equal 'evaluated', final['status']
    assert_equal 'ok', final['result']['notes']
  end

  def test_transition_rejects_invalid
    entry = @store.create(title: 'X', motivation: 'Y')
    err = assert_raises(ArgumentError) { @store.transition(entry['id'], 'merged') }
    assert_match(/cannot transition/, err.message)
  end

  def test_transition_unknown_proposal
    assert_raises(ArgumentError) { @store.transition('nope', 'approved') }
  end

  def test_failed_can_be_rolled_back
    entry = @store.create(title: 'X', motivation: 'Y')
    @store.transition(entry['id'], 'approved')
    @store.transition(entry['id'], 'running')
    @store.transition(entry['id'], 'failed')
    final = @store.transition(entry['id'], 'rolled_back')
    assert_equal 'rolled_back', final['status']
  end

  def test_attach_result_merges
    entry = @store.create(title: 'X', motivation: 'Y')
    @store.attach_result(entry['id'], 'worktree_path' => '/tmp/wt')
    @store.attach_result(entry['id'], 'branch' => 'evo/x')
    found = @store.find(entry['id'])
    assert_equal '/tmp/wt', found['result']['worktree_path']
    assert_equal 'evo/x', found['result']['branch']
  end

  def test_list_filter
    a = @store.create(title: 'A', motivation: 'a')
    @store.create(title: 'B', motivation: 'b')
    @store.transition(a['id'], 'approved')

    assert_equal 2, @store.list.size
    assert_equal 1, @store.list(status: 'approved').size
    assert_equal 1, @store.list(status: 'proposed').size
    assert_equal 0, @store.list(status: 'merged').size
  end

  def test_to_line_and_to_text
    entry = @store.create(title: 'X', motivation: 'Y')
    line = Rubycog::Proposal.to_line(entry)
    assert_includes line, '[proposed/feature]'
    assert_includes line, 'X'

    text = Rubycog::Proposal.to_text(entry)
    assert_includes text, 'status: proposed'
    assert_includes text, 'motivation: Y'
  end
end

class WorktreeTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-wt')
    @base = File.join(@dir, 'wts')
    # Build a tiny git repo to act as the "project".
    @repo = File.join(@dir, 'repo')
    FileUtils.mkdir_p(@repo)
    run_git(@repo, 'init', '-q', '-b', 'main')
    run_git(@repo, 'config', 'user.email', 't@example.com')
    run_git(@repo, 'config', 'user.name', 'tester')
    File.write(File.join(@repo, 'README.md'), "hello\n")
    run_git(@repo, 'add', 'README.md')
    run_git(@repo, 'commit', '-q', '-m', 'init')

    @wt = Rubycog::Worktree.new(root: @repo, base: @base)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_create_and_remove
    path = @wt.create('prop-test-1')
    assert File.directory?(path)
    assert File.exist?(File.join(path, 'README.md'))
    assert_equal 'evo/prop-test-1', @wt.branch_for('prop-test-1')

    @wt.remove('prop-test-1')
    refute File.exist?(path)
    refute @wt.exist?('prop-test-1')
  end

  def test_create_rejects_duplicate
    @wt.create('prop-dup')
    assert_raises(Rubycog::Worktree::Error) { @wt.create('prop-dup') }
    @wt.remove('prop-dup')
  end

  def test_remove_is_idempotent
    @wt.remove('prop-never-existed')
  end

  def test_inside_runs_git_in_worktree
    @wt.create('prop-x')
    File.write(File.join(@wt.path_for('prop-x'), 'new.txt'), "x\n")
    result = @wt.inside('prop-x', 'status', '--short')
    assert_includes result.stdout, 'new.txt'
    @wt.remove('prop-x')
  end

  def test_inside_raises_when_missing
    assert_raises(Rubycog::Worktree::Error) { @wt.inside('nope', 'status') }
  end

  def test_ensure_git_repo_raises_outside_repo
    plain = Dir.mktmpdir('not-a-repo')
    wt = Rubycog::Worktree.new(root: plain, base: @base)
    assert_raises(Rubycog::Worktree::Error) { wt.create('prop-x') }
  ensure
    FileUtils.remove_entry(plain) if plain
  end

  private

  def run_git(dir, *args)
    out, err, status = Open3.capture3('git', *args, chdir: dir)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out
  end
end

class EvolutionToolsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-evo')
    @prop_dir = File.join(@dir, 'proposals')
    @store = Rubycog::Proposal.new(dir: @prop_dir)

    # Real git repo with whitelisted structure so SourcePath.resolve accepts
    # edits inside the worktree.
    @repo = File.join(@dir, 'repo')
    FileUtils.mkdir_p(File.join(@repo, 'lib', 'rubycog'))
    File.write(File.join(@repo, 'lib', 'rubycog', 'thing.rb'), "class Thing\nend\n")
    File.write(File.join(@repo, 'Rakefile'), "# empty\n")
    File.write(File.join(@repo, 'Gemfile'), "# empty\n")
    run_git('init', '-q', '-b', 'main')
    run_git('config', 'user.email', 't@example.com')
    run_git('config', 'user.name', 'tester')
    run_git('add', '.')
    run_git('commit', '-q', '-m', 'init')

    @worktree = Rubycog::Worktree.new(root: @repo, base: File.join(@dir, 'wts'))
    @context = Rubycog::Evolution::Context.new(
      root: @repo, proposals: @store, worktree: @worktree
    )
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_propose_and_list
    propose = Rubycog::ProposeEvolutionTool.new(context: @context)
    out = propose.execute(title: 'Add retry', motivation: 'Flaky', touches: ['lib/rubycog/thing.rb'])
    assert_includes out, 'created proposal'
    assert_includes out, 'Add retry'

    list = Rubycog::ListProposalsTool.new(context: @context)
    lines = list.execute
    assert_includes lines, '[proposed/feature]'
    assert_includes lines, 'Add retry'
  end

  def test_list_filters_by_status
    propose = Rubycog::ProposeEvolutionTool.new(context: @context)
    propose.execute(title: 'A', motivation: 'a')
    list = Rubycog::ListProposalsTool.new(context: @context)
    assert_includes list.execute(status: 'proposed'), 'A'
    assert_includes list.execute(status: 'merged'), 'no proposals matched'
    assert_includes list.execute(status: 'nope'), 'unknown status'
  end

  def test_approve_and_run_happy_path
    proposal = @store.create(title: 'X', motivation: 'Y')
    approve = Rubycog::ApproveProposalTool.new(context: @context)
    out = approve.execute(id: proposal['id'])
    assert_includes out, 'approved'

    run = Rubycog::RunEvolutionTool.new(context: @context)
    out = run.execute(id: proposal['id'])
    assert_includes out, 'started proposal'
    assert_includes out, 'evo/'

    assert_equal 'running', @store.find(proposal['id'])['status']
    assert @worktree.exist?(proposal['id'])
  end

  def test_run_requires_approved_state
    proposal = @store.create(title: 'X', motivation: 'Y')
    run = Rubycog::RunEvolutionTool.new(context: @context)
    out = run.execute(id: proposal['id'])
    assert_includes out, 'expected approved'
  end

  def test_run_rejects_second_concurrent
    a = @store.create(title: 'A', motivation: 'a')
    b = @store.create(title: 'B', motivation: 'b')
    @store.transition(a['id'], 'approved')
    @store.transition(b['id'], 'approved')
    run = Rubycog::RunEvolutionTool.new(context: @context)
    run.execute(id: a['id'])
    out = run.execute(id: b['id'])
    assert_includes out, 'another proposal is already running'
  end

  def test_evolution_edit_writes_inside_worktree
    proposal = @store.create(title: 'X', motivation: 'Y')
    @store.transition(proposal['id'], 'approved')
    @context.start!(proposal['id'])

    edit = Rubycog::EvolutionEditTool.new(context: @context)
    out = edit.execute(
      path: 'lib/rubycog/thing.rb',
      old_string: "class Thing\nend\n",
      new_string: "class Thing\n  def hi = 1\nend\n",
      reason: 'test'
    )
    assert_includes out, 'edited lib/rubycog/thing.rb'

    wt_file = File.join(@worktree.path_for(proposal['id']), 'lib', 'rubycog', 'thing.rb')
    assert_includes File.read(wt_file), 'def hi'

    # The main checkout must be untouched.
    main_file = File.join(@repo, 'lib', 'rubycog', 'thing.rb')
    refute_includes File.read(main_file), 'def hi'
  end

  def test_evolution_edit_requires_running
    edit = Rubycog::EvolutionEditTool.new(context: @context)
    out = edit.execute(path: 'lib/rubycog/thing.rb', old_string: 'x', new_string: 'y')
    assert_includes out, 'no proposal is running'
  end

  def test_finish_evolution_marks_evaluated
    proposal = @store.create(title: 'X', motivation: 'Y')
    @store.transition(proposal['id'], 'approved')
    @context.start!(proposal['id'])
    edit = Rubycog::EvolutionEditTool.new(context: @context)
    edit.execute(path: 'lib/rubycog/thing.rb',
                 old_string: "class Thing\nend\n",
                 new_string: "class Thing\n  def hi = 1\nend\n")

    finish = Rubycog::FinishEvolutionTool.new(context: @context)
    out = finish.execute(notes: 'looks good', success: true)
    assert_includes out, 'evaluated proposal'
    assert_equal 'evaluated', @store.find(proposal['id'])['status']
  end

  def test_finish_evolution_marks_failed
    proposal = @store.create(title: 'X', motivation: 'Y')
    @store.transition(proposal['id'], 'approved')
    @context.start!(proposal['id'])
    finish = Rubycog::FinishEvolutionTool.new(context: @context)
    out = finish.execute(notes: 'tests blew up', success: false)
    assert_includes out, 'failed proposal'
    assert_equal 'failed', @store.find(proposal['id'])['status']
  end

  def test_rollback_from_evaluated
    proposal = @store.create(title: 'X', motivation: 'Y')
    @store.transition(proposal['id'], 'approved')
    @context.start!(proposal['id'])
    @context.mark_evaluated!(proposal['id'], notes: 'ok')

    rollback = Rubycog::RollbackEvolutionTool.new(context: @context)
    out = rollback.execute(id: proposal['id'])
    assert_includes out, 'rolled back'
    assert_equal 'rolled_back', @store.find(proposal['id'])['status']
    refute @worktree.exist?(proposal['id'])
  end

  def test_rollback_from_failed
    proposal = @store.create(title: 'X', motivation: 'Y')
    @store.transition(proposal['id'], 'approved')
    @context.start!(proposal['id'])
    @context.mark_failed!(proposal['id'], 'boom')

    rollback = Rubycog::RollbackEvolutionTool.new(context: @context)
    out = rollback.execute(id: proposal['id'])
    assert_includes out, 'rolled back'
    assert_equal 'rolled_back', @store.find(proposal['id'])['status']
  end

  def test_rollback_rejects_proposed
    proposal = @store.create(title: 'X', motivation: 'Y')
    rollback = Rubycog::RollbackEvolutionTool.new(context: @context)
    out = rollback.execute(id: proposal['id'])
    assert_includes out, 'cannot rollback from proposed'
  end

  # -- budget enforcement -------------------------------------------------

  def test_budget_max_files_blocks_second_file
    proposal = @store.create(title: 'X', motivation: 'Y',
                             budget: { 'max_files' => 1, 'max_lines' => 100 })
    @store.transition(proposal['id'], 'approved')
    @context.start!(proposal['id'])

    edit = Rubycog::EvolutionEditTool.new(context: @context)
    out1 = edit.execute(path: 'lib/rubycog/thing.rb',
                        old_string: "class Thing\nend\n",
                        new_string: "class Thing\n  def a = 1\nend\n")
    assert_includes out1, 'edited lib/rubycog/thing.rb'

    File.write(File.join(@repo, 'lib', 'rubycog', 'other.rb'), "class Other\nend\n")
    # Bring the second file into the worktree via git so it exists there too.
    wt_path = @worktree.path_for(proposal['id'])
    File.write(File.join(wt_path, 'lib', 'rubycog', 'other.rb'), "class Other\nend\n")

    out2 = edit.execute(path: 'lib/rubycog/other.rb',
                        old_string: "class Other\nend\n",
                        new_string: "class Other\n  def b = 2\nend\n")
    assert_includes out2, 'budget exceeded'
    assert_includes out2, 'max_files=1'
  end

  def test_budget_max_lines_blocks_large_edit
    proposal = @store.create(title: 'X', motivation: 'Y',
                             budget: { 'max_files' => 5, 'max_lines' => 5 })
    @store.transition(proposal['id'], 'approved')
    @context.start!(proposal['id'])

    edit = Rubycog::EvolutionEditTool.new(context: @context)
    # Single edit of ~20 lines delta should blow a 5-line budget.
    new_body = "class Thing\n" + (1..10).map { |i| "  def m#{i} = #{i}\n" }.join + "end\n"
    out = edit.execute(path: 'lib/rubycog/thing.rb',
                       old_string: "class Thing\nend\n",
                       new_string: new_body)
    assert_includes out, 'budget exceeded'
    assert_includes out, 'max_lines=5'
  end

  def test_budget_allows_within_limits
    proposal = @store.create(title: 'X', motivation: 'Y',
                             budget: { 'max_files' => 2, 'max_lines' => 50 })
    @store.transition(proposal['id'], 'approved')
    @context.start!(proposal['id'])

    edit = Rubycog::EvolutionEditTool.new(context: @context)
    out = edit.execute(path: 'lib/rubycog/thing.rb',
                       old_string: "class Thing\nend\n",
                       new_string: "class Thing\n  def a = 1\nend\n")
    assert_includes out, 'edited lib/rubycog/thing.rb'
    refute_includes out, 'budget exceeded'
  end

  def test_budget_reports_delta_in_output
    proposal = @store.create(title: 'X', motivation: 'Y')
    @store.transition(proposal['id'], 'approved')
    @context.start!(proposal['id'])
    edit = Rubycog::EvolutionEditTool.new(context: @context)
    out = edit.execute(path: 'lib/rubycog/thing.rb',
                       old_string: "class Thing\nend\n",
                       new_string: "class Thing\n  def a = 1\n  def b = 2\nend\n")
    assert_match(/Δ\d+ lines/, out)
  end

  private

  def run_git(*args)
    out, err, status = Open3.capture3('git', *args, chdir: @repo)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out
  end
end
