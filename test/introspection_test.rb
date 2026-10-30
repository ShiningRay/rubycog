# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'

class ProposalCategoryTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-cat')
    @store = Rubycog::Proposal.new(dir: @dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_default_category_is_feature
    entry = @store.create(title: 'X', motivation: 'Y')
    assert_equal 'feature', entry['category']
  end

  def test_accepts_valid_categories
    %w[feature refactor performance].each do |cat|
      entry = @store.create(title: "X #{cat}", motivation: 'Y', category: cat)
      assert_equal cat, entry['category']
    end
  end

  def test_rejects_unknown_category
    assert_raises(ArgumentError) do
      @store.create(title: 'X', motivation: 'Y', category: 'chaos')
    end
  end

  def test_to_line_includes_category
    entry = @store.create(title: 'X', motivation: 'Y', category: 'refactor')
    assert_includes Rubycog::Proposal.to_line(entry), '[proposed/refactor]'
  end

  def test_to_text_includes_category
    entry = @store.create(title: 'X', motivation: 'Y', category: 'performance')
    assert_includes Rubycog::Proposal.to_text(entry), 'category: performance'
  end

  def test_legacy_yaml_without_category_defaults_to_feature
    path = File.join(@dir, 'prop-old.yaml')
    File.write(path, { 'id' => 'prop-old', 'title' => 'Old', 'motivation' => 'x', 'status' => 'proposed' }.to_yaml)
    entry = @store.find('prop-old')
    assert_equal 'feature', entry['category']
  end
end

class HeuristicScanTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-heur')
    FileUtils.mkdir_p(File.join(@dir, 'lib'))
    @scan = Rubycog::HeuristicScan.new(root: @dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write(name, content)
    path = File.join(@dir, 'lib', name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def test_detects_backup_files
    write('a.rb.bak', "class A; end\n")
    findings = @scan.scan.select { |f| f.rule == 'BackupFile' }
    assert_equal 1, findings.size
  end

  def test_detects_long_method
    body = (1..30).map { |i| "  x#{i} = #{i}\n" }.join
    write('a.rb', "class A\n  def long\n#{body}  end\nend\n")
    findings = @scan.scan.select { |f| f.rule == 'LongMethod' }
    assert_equal 1, findings.size
    assert_includes findings.first.message, 'long'
  end

  def test_ignores_short_method
    write('a.rb', "class A\n  def short\n    1\n  end\nend\n")
    findings = @scan.scan.select { |f| f.rule == 'LongMethod' }
    assert_empty findings
  end

  def test_detects_long_file
    lines = (1..300).map { |i| "# line #{i}\n" }.join
    write('big.rb', lines)
    findings = @scan.scan.select { |f| f.rule == 'LongFile' }
    assert_equal 1, findings.size
  end

  def test_detects_too_many_params
    write('a.rb', "class A\n  def m(a, b, c, d, e, f)\n  end\nend\n")
    findings = @scan.scan.select { |f| f.rule == 'TooManyParams' }
    assert_equal 1, findings.size
    assert_includes findings.first.message, '6 positional'
  end

  def test_ignores_kwargs_when_counting_positional
    write('a.rb', "class A\n  def m(a, b:, c:, d:, e:)\n  end\nend\n")
    findings = @scan.scan.select { |f| f.rule == 'TooManyParams' }
    assert_empty findings
  end

  def test_detects_commented_code
    write('a.rb', "class A\n  # def old_method\n  # end\nend\n")
    findings = @scan.scan.select { |f| f.rule == 'CommentedCode' }
    assert_operator findings.size, :>=, 1
  end

  def test_detects_duplicate_blocks
    block = (1..6).map { |i| "some_real_line_of_code_#{i}" }.join("\n")
    write('a.rb', "#{block}\n")
    write('b.rb', "#{block}\n")
    write('c.rb', "#{block}\n")
    findings = @scan.scan.select { |f| f.rule == 'DuplicateBlock' }
    assert_operator findings.size, :>=, 1
  end
end

class StaticAnalysisTest < Minitest::Test
  def test_parse_rubocop_json
    json = <<~JSON
      {"files":[{"path":"lib/a.rb","offenses":[{"cop_name":"Style/Foo","message":"bad","severity":"convention","location":{"start_line":3}}]}]}
    JSON
    sa = Rubycog::StaticAnalysis.allocate
    findings = sa.send(:parse_rubocop, json)
    assert_equal 1, findings.size
    f = findings.first
    assert_equal 'lib/a.rb', f.path
    assert_equal 3, f.line
    assert_equal 'Style/Foo', f.rule
    assert_equal 'bad', f.message
  end

  def test_parse_reek_json
    json = <<~JSON
      [{"source":"lib/b.rb","lines":[12],"smell_type":"LongMethod","message":"too long"}]
    JSON
    sa = Rubycog::StaticAnalysis.allocate
    findings = sa.send(:parse_reek, json)
    assert_equal 1, findings.size
    f = findings.first
    assert_equal 'lib/b.rb', f.path
    assert_equal 12, f.line
    assert_equal 'LongMethod', f.rule
  end

  def test_handles_missing_tool_gracefully
    sa = Rubycog::StaticAnalysis.new(root: '/nonexistent-path-xyz')
    result = sa.rubocop
    refute result.ok?
    refute_nil result.error
  end
end

class IntrospectionTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-intro')
    FileUtils.mkdir_p(File.join(@dir, 'lib'))
    File.write(File.join(@dir, 'lib', 'a.rb'), "class A\n  def m(a, b, c, d, e, f)\n  end\nend\n")
    @report_dir = File.join(@dir, 'reports')

    # Stub static analysis so we don't depend on rubocop/reek in this test.
    stub_static = Class.new do
      def rubocop(paths: nil)
        Rubycog::StaticAnalysis::Result.new(tool: 'rubocop', ok: true, findings: [], error: nil)
      end

      def reek(paths: nil)
        Rubycog::StaticAnalysis::Result.new(tool: 'reek', ok: true, findings: [], error: nil)
      end
    end.new

    @intro = Rubycog::Introspection.new(root: @dir, dir: @report_dir, static: stub_static)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_run_writes_report
    result = @intro.run
    assert File.exist?(result[:report_path])
    content = File.read(result[:report_path])
    assert_includes content, 'Introspection report'
    assert_includes content, 'TooManyParams'
  end

  def test_summary_includes_counts
    result = @intro.run
    assert_includes result[:summary], 'rubocop: 0 findings'
    assert_includes result[:summary], 'TooManyParams: 1'
  end

  def test_recent_reports_returns_newest_first
    @intro.run
    sleep 1.1
    @intro.run
    reports = @intro.recent_reports(limit: 5)
    assert_equal 2, reports.size
    assert reports[0] > reports[1]
  end
end

class IntrospectCodeToolTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-ict')
    FileUtils.mkdir_p(File.join(@dir, 'lib'))
    File.write(File.join(@dir, 'lib', 'a.rb'), "class A\n  def m(a, b, c, d, e, f)\n  end\nend\n")

    stub_static = Class.new do
      def rubocop(paths: nil)
        Rubycog::StaticAnalysis::Result.new(tool: 'rubocop', ok: true, findings: [], error: nil)
      end

      def reek(paths: nil)
        Rubycog::StaticAnalysis::Result.new(tool: 'reek', ok: true, findings: [], error: nil)
      end
    end.new

    intro = Rubycog::Introspection.new(
      root: @dir, dir: File.join(@dir, 'reports'), static: stub_static
    )
    @tool = Rubycog::IntrospectCodeTool.new(introspection: intro)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_execute_returns_report_path_and_summary
    out = @tool.execute
    assert_includes out, 'introspection complete'
    assert_includes out, 'report:'
    assert_includes out, 'Top offenders'
    assert_includes out, 'TooManyParams'
  end
end

class FinishEvolutionCategoryTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-cat-fin')
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

  def test_refactor_allows_regression_without_force
    proposal = @store.create(title: 'X', motivation: 'Y', category: 'refactor')
    @store.transition(proposal['id'], 'approved')
    @context.start!(proposal['id'])
    # Force a regression into the worktree benchmark.
    File.write(File.join(@worktree.path_for(proposal['id']), 'benchmarks', 'speed.rb'), "puts 50\n")
    Rubycog::EvolutionBenchmarkTool.new(context: @context).execute

    finish = Rubycog::FinishEvolutionTool.new(context: @context)
    out = finish.execute(notes: 'refactor', success: true)
    assert_includes out, 'evaluated proposal'
    assert_includes out, 'refactor: regression allowed'
  end

  def test_performance_blocks_regression_even_with_force
    proposal = @store.create(title: 'X', motivation: 'Y', category: 'performance')
    @store.transition(proposal['id'], 'approved')
    @context.start!(proposal['id'])
    File.write(File.join(@worktree.path_for(proposal['id']), 'benchmarks', 'speed.rb'), "puts 50\n")
    Rubycog::EvolutionBenchmarkTool.new(context: @context).execute

    finish = Rubycog::FinishEvolutionTool.new(context: @context)
    out = finish.execute(notes: 'try', success: true, force: true)
    assert_includes out, 'performance proposal must not regress'
    assert_equal 'running', @store.find(proposal['id'])['status']
  end

  def test_performance_requires_benchmark_to_be_run
    proposal = @store.create(title: 'X', motivation: 'Y', category: 'performance')
    @store.transition(proposal['id'], 'approved')
    @context.start!(proposal['id'])
    # Note: no benchmark run.

    finish = Rubycog::FinishEvolutionTool.new(context: @context)
    out = finish.execute(notes: 'no bench', success: true)
    assert_includes out, 'requires evolution_benchmark'
  end

  def test_performance_passes_when_no_regression
    proposal = @store.create(title: 'X', motivation: 'Y', category: 'performance')
    @store.transition(proposal['id'], 'approved')
    @context.start!(proposal['id'])
    # Same benchmark score — no regression.
    Rubycog::EvolutionBenchmarkTool.new(context: @context).execute

    finish = Rubycog::FinishEvolutionTool.new(context: @context)
    out = finish.execute(notes: 'ok', success: true)
    assert_includes out, 'evaluated proposal'
  end

  private

  def run_git(*args)
    out, err, status = Open3.capture3('git', *args, chdir: @repo)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out
  end
end
