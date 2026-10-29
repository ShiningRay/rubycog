# frozen_string_literal: true

require_relative 'test_helper'
require 'fileutils'
require 'tmpdir'

class SelfIterationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-self')
    @path = File.join(@dir, 'self_iteration.json')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_records_edits_and_tests
    iteration = Rubycog::SelfIteration.new(path: @path)
    iteration.record_edit(path: 'lib/rubycog/a.rb', reason: 'fix', ok: true, diff: "+x\n")
    iteration.record_test(paths: ['test/a_test.rb'], ok: true, exit_status: 0, output: 'ok')

    assert_equal 2, iteration.records.size
    assert_includes iteration.summary, 'last edit lib/rubycog/a.rb (ok)'
    assert_includes iteration.summary, 'last test passed'
    assert_includes iteration.to_text, 'edit'
    assert_includes iteration.to_text, 'test'
    assert_equal 0o600, File.stat(@path).mode & 0o777
  end

  def test_survives_a_corrupt_file
    File.write(@path, '{oops')

    assert_empty Rubycog::SelfIteration.new(path: @path).records
  end

  def test_keeps_only_recent_records
    iteration = Rubycog::SelfIteration.new(path: @path)
    55.times { |i| iteration.record_edit(path: "lib/rubycog/#{i}.rb", reason: 'r', ok: true) }

    assert_equal Rubycog::SelfIteration::MAX_RECORDS, iteration.records.size
    assert_equal 'lib/rubycog/54.rb', iteration.records.last['path']
  end
end

class SelfIterationToolsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-tools')
    @lib = File.join(@dir, 'lib', 'rubycog')
    @test = File.join(@dir, 'test')
    FileUtils.mkdir_p(@lib)
    FileUtils.mkdir_p(@test)
    File.write(File.join(@lib, 'agent.rb'), "A = 1\n")
    File.write(File.join(@test, 'agent_test.rb'), "# placeholder\n")
    @iteration = Rubycog::SelfIteration.new(path: File.join(@dir, 'self.json'))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_read_source_returns_numbered_text
    tool = Rubycog::ReadSourceTool.new(root: @dir)
    text = tool.execute(path: 'lib/rubycog/agent.rb')

    assert_includes text, '# lib/rubycog/agent.rb'
    assert_includes text, '   1 | A = 1'
  end

  def test_edit_source_writes_and_records
    tool = Rubycog::EditSourceTool.new(root: @dir, self_iteration: @iteration)
    result = tool.execute(path: 'lib/rubycog/agent.rb', old_string: 'A = 1', new_string: 'A = 2',
                          reason: 'increment')

    assert_includes result, 'edited lib/rubycog/agent.rb'
    assert_includes File.read(File.join(@lib, 'agent.rb')), 'A = 2'
    assert_equal 'edit', @iteration.records.last['kind']
    assert_equal 'lib/rubycog/agent.rb', @iteration.records.last['path']
  end

  def test_edit_source_creates_a_new_test_file
    tool = Rubycog::EditSourceTool.new(root: @dir, self_iteration: @iteration)
    result = tool.execute(path: 'test/new_test.rb', old_string: '',
                          new_string: "require_relative 'test_helper'\n", reason: 'new test')

    assert_includes result, 'edited test/new_test.rb'
    assert File.exist?(File.join(@test, 'new_test.rb'))
  end

  def test_edit_source_rejects_empty_reason
    tool = Rubycog::EditSourceTool.new(root: @dir, self_iteration: @iteration)
    result = tool.execute(path: 'lib/rubycog/agent.rb', old_string: 'A = 1', new_string: 'A = 2',
                          reason: ' ')

    assert_includes result, 'reason is required'
    assert_equal "A = 1\n", File.read(File.join(@lib, 'agent.rb'))
  end

  def test_edit_source_rejects_non_whitelisted_paths
    tool = Rubycog::EditSourceTool.new(root: @dir, self_iteration: @iteration)
    result = tool.execute(path: '.env', old_string: '', new_string: 'x', reason: 'nope')

    assert_includes result, 'edit_source error'
    assert_empty @iteration.records
  end

  def test_run_tests_uses_the_injected_command
    tool = Rubycog::RunTestsTool.new(
      root: @dir, self_iteration: @iteration,
      command: [RbConfig.ruby, '-e', 'puts "ok"; exit 0']
    )
    output = tool.execute

    assert_includes output, 'exit=0 (passed)'
    assert_includes output, 'ok'
    assert_equal 'test', @iteration.records.last['kind']
  end

  def test_run_tests_accepts_an_array_of_paths
    tool = Rubycog::RunTestsTool.new(
      root: @dir,
      command: [RbConfig.ruby, '-e', 'puts ARGV.join(","); exit 0']
    )
    output = tool.execute(paths: ['test/agent_test.rb'])

    assert_includes output, 'exit=0 (passed)'
    assert_includes output, 'test/agent_test.rb'
  end

  def test_run_tests_rejects_non_test_paths
    tool = Rubycog::RunTestsTool.new(root: @dir, command: [RbConfig.ruby, '-e', 'exit 0'])
    output = tool.execute(paths: 'lib/rubycog/agent.rb')

    assert_includes output, 'run_tests error'
  end
end
