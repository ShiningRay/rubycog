# frozen_string_literal: true

require_relative 'test_helper'
require 'fileutils'
require 'tmpdir'

class SourcePathTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-source')
    @lib = File.join(@dir, 'lib', 'rubycog')
    FileUtils.mkdir_p(@lib)
    File.write(File.join(@lib, 'agent.rb'), "class Agent\nend\n")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_resolves_whitelisted_files
    full, relative = Rubycog::SourcePath.resolve('lib/rubycog/agent.rb', root: @dir)

    assert_equal File.join(@lib, 'agent.rb'), full
    assert_equal 'lib/rubycog/agent.rb', relative
  end

  def test_rejects_escape_and_secrets
    assert_raises(ArgumentError) { Rubycog::SourcePath.resolve('../outside.rb', root: @dir) }
    assert_raises(ArgumentError) { Rubycog::SourcePath.resolve('test/../lib/x.rb', root: @dir) }
    assert_raises(ArgumentError) { Rubycog::SourcePath.resolve('.env', root: @dir) }
    assert_raises(ArgumentError) { Rubycog::SourcePath.resolve('Gemfile.lock', root: @dir) }
    assert_raises(ArgumentError) { Rubycog::SourcePath.resolve('/etc/passwd', root: @dir) }
  end

  def test_rejects_symlink_escape
    File.symlink('/etc/passwd', File.join(@lib, 'link.rb'))

    assert_raises(ArgumentError) { Rubycog::SourcePath.resolve('lib/rubycog/link.rb', root: @dir) }
  end

  def test_allows_reading_but_not_writing_protected_tools
    Rubycog::SourcePath.resolve('lib/rubycog/source_edit.rb', root: @dir, must_exist: false)

    assert_raises(ArgumentError) do
      Rubycog::SourcePath.resolve('lib/rubycog/source_edit.rb', root: @dir, must_exist: false, write: true)
    end
  end
end

class SourceEditTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-edit')
    @path = File.join(@dir, 'lib', 'rubycog', 'agent.rb')
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, "class Agent\n  VALUE = 1\nend\n")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_reads_numbered_lines
    text = Rubycog::SourceEdit.read(@path, 'lib/rubycog/agent.rb', start_line: 2, end_line: 2)

    assert_includes text, '   2 |   VALUE = 1'
  end

  def test_applies_unique_replacement_with_backup
    result = Rubycog::SourceEdit.apply(
      @path, 'lib/rubycog/agent.rb', 'VALUE = 1', 'VALUE = 2',
      reason: 'test', backup_root: File.join(@dir, '.rubycog', 'backups')
    )

    assert result[:ok]
    assert_includes File.read(@path), 'VALUE = 2'
    assert File.exist?(result[:backup])
    assert_includes result[:diff], '-  VALUE = 1'
    assert_includes result[:diff], '+  VALUE = 2'
  end

  def test_rejects_ambiguous_and_missing_matches
    assert_raises(ArgumentError) do
      Rubycog::SourceEdit.plan(@path, 'lib/rubycog/agent.rb', "\n", 'X')
    end
    assert_raises(ArgumentError) do
      Rubycog::SourceEdit.plan(@path, 'lib/rubycog/agent.rb', 'NOPE', 'X')
    end
  end

  def test_rolls_back_on_syntax_error
    result = Rubycog::SourceEdit.apply(
      @path, 'lib/rubycog/agent.rb', 'VALUE = 1', 'VALUE =',
      reason: 'broken', backup_root: File.join(@dir, '.rubycog', 'backups')
    )

    refute result[:ok]
    assert_equal 'syntax', result[:stage]
    assert_includes File.read(@path), 'VALUE = 1'
  end

  def test_skips_syntax_check_for_non_ruby_files
    path = File.join(@dir, 'README.md')
    File.write(path, "# Title\n")

    result = Rubycog::SourceEdit.apply(
      path, 'README.md', '# Title', '# Title v2',
      reason: 'docs', backup_root: File.join(@dir, '.rubycog', 'backups')
    )

    assert result[:ok]
    assert_includes result[:syntax], 'not a Ruby file'
    assert_equal "# Title v2\n", File.read(path)
  end

  def test_creates_new_docs_file_without_ruby_syntax_check
    path = File.join(@dir, 'docs', 'env.md')
    FileUtils.mkdir_p(File.dirname(path))

    result = Rubycog::SourceEdit.apply(
      path, 'docs/env.md', '', "# Env file\n",
      reason: 'docs', backup_root: File.join(@dir, '.rubycog', 'backups')
    )

    assert result[:ok]
    assert_equal "# Env file\n", File.read(path)
  end

  def test_still_checks_syntax_of_ruby_files
    result = Rubycog::SourceEdit.apply(
      @path, 'lib/rubycog/agent.rb', 'VALUE = 1', 'VALUE = 2',
      reason: 'test', backup_root: File.join(@dir, '.rubycog', 'backups')
    )

    assert result[:ok]
    assert_includes result[:syntax], 'Syntax OK'
  end
end
