# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'

class SuggestProposalsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-sugg')
    @exp_dir = File.join(@dir, 'experiences')
    @prop_dir = File.join(@dir, 'proposals')
    @experiences = Rubycog::Experience.new(dir: @exp_dir)
    @proposals = Rubycog::Proposal.new(dir: @prop_dir)
    @context = Rubycog::Evolution::Context.new(
      root: @dir, proposals: @proposals,
      worktree: Rubycog::Worktree.new(root: @dir, base: File.join(@dir, 'wts'))
    )
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_empty_when_no_experiences
    tool = Rubycog::SuggestProposalsTool.new(context: @context, experiences: @experiences)
    out = tool.execute
    assert_includes out, 'no experiences recorded yet'
  end

  def test_lists_unreferenced_experiences
    @experiences.create(source: 'https://a/1', summary: 'Skill bundles', tags: %w[agent])
    @experiences.create(source: 'https://a/2', summary: 'Retry logic')

    tool = Rubycog::SuggestProposalsTool.new(context: @context, experiences: @experiences)
    out = tool.execute
    assert_includes out, 'unreferenced experiences'
    assert_includes out, 'Skill bundles'
    assert_includes out, 'Retry logic'
  end

  def test_excludes_referenced_experiences
    a = @experiences.create(source: 'https://a/1', summary: 'Skill bundles')
    @experiences.create(source: 'https://a/2', summary: 'Retry logic')
    @proposals.create(title: 'Add skill', motivation: 'x', experience_id: a['id'])

    tool = Rubycog::SuggestProposalsTool.new(context: @context, experiences: @experiences)
    out = tool.execute
    refute_includes out, a['id']
    assert_includes out, 'Retry logic'
  end

  def test_all_referenced_returns_empty
    a = @experiences.create(source: 'https://a/1', summary: 'x')
    @proposals.create(title: 'X', motivation: 'x', experience_id: a['id'])

    tool = Rubycog::SuggestProposalsTool.new(context: @context, experiences: @experiences)
    out = tool.execute
    assert_includes out, 'no unreferenced experiences'
    assert_includes out, '1 total'
  end

  def test_respects_limit
    5.times { |i| @experiences.create(source: "https://a/#{i}", summary: "idea #{i}") }
    tool = Rubycog::SuggestProposalsTool.new(context: @context, experiences: @experiences)
    out = tool.execute(limit: 2)
    assert_includes out, 'showing 2'
  end
end

class BenchmarkRunnerTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-bench')
    @main = File.join(@dir, 'main')
    @wt = File.join(@dir, 'wt')
    FileUtils.mkdir_p(File.join(@main, 'benchmarks'))
    FileUtils.mkdir_p(File.join(@wt, 'benchmarks'))
    @runner = Rubycog::BenchmarkRunner.new
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_script(root, name, body)
    File.write(File.join(root, 'benchmarks', name), body)
  end

  def test_no_benchmarks_returns_empty
    cmp = @runner.compare(main_root: @main, worktree_root: @wt)
    assert_empty cmp[:results]
    assert_empty cmp[:skipped]
  end

  def test_compares_common_scripts
    write_script(@main, 'speed.rb', "puts 100\n")
    write_script(@wt, 'speed.rb', "puts 110\n")

    cmp = @runner.compare(main_root: @main, worktree_root: @wt)
    assert_equal 1, cmp[:results].size
    r = cmp[:results].first
    assert_equal 'speed.rb', r.name
    assert_in_delta 100.0, r.main_score
    assert_in_delta 110.0, r.worktree_score
    refute r.regressed
  end

  def test_detects_regression_when_score_drops
    write_script(@main, 'speed.rb', "puts 100\n")
    write_script(@wt, 'speed.rb', "puts 80\n")

    cmp = @runner.compare(main_root: @main, worktree_root: @wt)
    r = cmp[:results].first
    assert r.regressed
    assert @runner.regressed?(cmp[:results])
  end

  def test_respects_lower_direction
    write_script(@main, 'latency.rb', "puts 50\n")
    write_script(@wt, 'latency.rb', "puts 60\n")
    File.write(File.join(@main, 'benchmarks', 'latency.rb.direction'), "lower\n")
    File.write(File.join(@wt, 'benchmarks', 'latency.rb.direction'), "lower\n")

    cmp = @runner.compare(main_root: @main, worktree_root: @wt)
    r = cmp[:results].first
    assert_equal :lower, r.direction
    assert r.regressed
  end

  def test_within_tolerance_not_regression
    write_script(@main, 'speed.rb', "puts 100\n")
    write_script(@wt, 'speed.rb', "puts 97\n")  # 3% drop < 5% tolerance

    cmp = @runner.compare(main_root: @main, worktree_root: @wt)
    refute cmp[:results].first.regressed
  end

  def test_skips_scripts_present_in_only_one
    write_script(@main, 'only_main.rb', "puts 1\n")
    write_script(@wt, 'only_wt.rb', "puts 2\n")

    cmp = @runner.compare(main_root: @main, worktree_root: @wt)
    assert_empty cmp[:results]
    assert_equal %w[only_main.rb only_wt.rb].sort, cmp[:skipped].sort
  end

  def test_handles_script_error
    write_script(@main, 'bad.rb', "raise 'boom'\n")
    write_script(@wt, 'bad.rb', "puts 1\n")

    cmp = @runner.compare(main_root: @main, worktree_root: @wt)
    r = cmp[:results].first
    refute_nil r.error
    assert_includes r.error, 'main:'
  end

  def test_handles_no_numeric_output
    write_script(@main, 'nan.rb', "puts 'not a number'\n")
    write_script(@wt, 'nan.rb', "puts 1\n")

    cmp = @runner.compare(main_root: @main, worktree_root: @wt)
    r = cmp[:results].first
    assert_includes r.error, 'no numeric score'
  end

  def test_parses_tab_separated_output
    write_script(@main, 'speed.rb', "puts \"speed\\t100\"\n")
    write_script(@wt, 'speed.rb', "puts \"speed\\t120\"\n")

    cmp = @runner.compare(main_root: @main, worktree_root: @wt)
    r = cmp[:results].first
    assert_in_delta 100.0, r.main_score
    assert_in_delta 120.0, r.worktree_score
  end

  def test_format_comparison_renders
    write_script(@main, 'speed.rb', "puts 100\n")
    write_script(@wt, 'speed.rb', "puts 80\n")
    cmp = @runner.compare(main_root: @main, worktree_root: @wt)
    out = @runner.format_comparison(cmp)
    assert_includes out, 'speed.rb'
    assert_includes out, 'REGRESSED'
  end
end

class EvolutionBenchmarkToolTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-evo-bench')
    @prop_dir = File.join(@dir, 'proposals')
    @store = Rubycog::Proposal.new(dir: @prop_dir)

    @repo = File.join(@dir, 'repo')
    FileUtils.mkdir_p(File.join(@repo, 'lib', 'rubycog'))
    FileUtils.mkdir_p(File.join(@repo, 'benchmarks'))
    File.write(File.join(@repo, 'lib', 'rubycog', 'thing.rb'), "class Thing\nend\n")
    File.write(File.join(@repo, 'Rakefile'), '')
    File.write(File.join(@repo, 'Gemfile'), '')
    File.write(File.join(@repo, 'benchmarks', 'speed.rb'), "puts 100\n")

    run_git('init', '-q', '-b', 'main')
    run_git('config', 'user.email', 't@e.c')
    run_git('config', 'user.name', 't')
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

  def test_no_running_proposal_errors
    tool = Rubycog::EvolutionBenchmarkTool.new(context: @context)
    out = tool.execute
    assert_includes out, 'no proposal is running'
  end

  def test_passes_when_no_regression
    proposal = @store.create(title: 'X', motivation: 'Y')
    @store.transition(proposal['id'], 'approved')
    @context.start!(proposal['id'])

    # Make the worktree's benchmark return the same number.
    wt_bench = File.join(@worktree.path_for(proposal['id']), 'benchmarks', 'speed.rb')
    File.write(wt_bench, "puts 100\n")

    tool = Rubycog::EvolutionBenchmarkTool.new(context: @context)
    out = tool.execute
    assert_includes out, 'no regression'
    assert_equal false, @store.find(proposal['id']).dig('result', 'benchmark_regressed')
  end

  def test_flags_regression
    proposal = @store.create(title: 'X', motivation: 'Y')
    @store.transition(proposal['id'], 'approved')
    @context.start!(proposal['id'])

    wt_bench = File.join(@worktree.path_for(proposal['id']), 'benchmarks', 'speed.rb')
    File.write(wt_bench, "puts 50\n")  # 50% drop

    tool = Rubycog::EvolutionBenchmarkTool.new(context: @context)
    out = tool.execute
    assert_includes out, 'REGRESSION DETECTED'
    assert_equal true, @store.find(proposal['id']).dig('result', 'benchmark_regressed')
  end

  def test_finish_blocks_success_when_regressed
    proposal = @store.create(title: 'X', motivation: 'Y')
    @store.transition(proposal['id'], 'approved')
    @context.start!(proposal['id'])

    wt_bench = File.join(@worktree.path_for(proposal['id']), 'benchmarks', 'speed.rb')
    File.write(wt_bench, "puts 50\n")

    Rubycog::EvolutionBenchmarkTool.new(context: @context).execute

    finish = Rubycog::FinishEvolutionTool.new(context: @context)
    out = finish.execute(notes: 'try to pass anyway', success: true)
    assert_includes out, 'benchmark regression detected'
    assert_equal 'running', @store.find(proposal['id'])['status']
  end

  def test_finish_force_overrides_regression
    proposal = @store.create(title: 'X', motivation: 'Y')
    @store.transition(proposal['id'], 'approved')
    @context.start!(proposal['id'])

    wt_bench = File.join(@worktree.path_for(proposal['id']), 'benchmarks', 'speed.rb')
    File.write(wt_bench, "puts 50\n")

    Rubycog::EvolutionBenchmarkTool.new(context: @context).execute

    finish = Rubycog::FinishEvolutionTool.new(context: @context)
    out = finish.execute(notes: 'force it', success: true, force: true)
    assert_includes out, 'evaluated proposal'
    assert_includes out, 'forced despite regression'
    assert_equal 'evaluated', @store.find(proposal['id'])['status']
  end

  private

  def run_git(*args)
    out, err, status = Open3.capture3('git', *args, chdir: @repo)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out
  end
end
