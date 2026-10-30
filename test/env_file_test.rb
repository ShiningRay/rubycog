# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require 'minitest/mock'

# Covers Rubycog::EnvFile: which files are read, who wins on a clash, and that
# the CLI loads .env before the provider configuration reads ENV.
class EnvFileTest < Minitest::Test
  def teardown
    Array(@keys).each { |key| ENV.delete(key) }
    super
  end

  def test_loads_keys_from_a_candidate_file
    Dir.mktmpdir do |dir|
      path = write_env(dir, "RUBYCOG_ENV_TEST_A=from-file\n# comment\n" \
                            "export RUBYCOG_ENV_TEST_B=\"two words\" # trailing\n")

      assert_equal [path], Rubycog::EnvFile.load([path])
      assert_equal 'from-file', ENV['RUBYCOG_ENV_TEST_A']
      assert_equal 'two words', ENV['RUBYCOG_ENV_TEST_B']
    end
  end

  def test_a_real_environment_variable_wins_over_the_file
    Dir.mktmpdir do |dir|
      track('RUBYCOG_ENV_TEST_SHELL', 'from-shell')
      path = write_env(dir, "RUBYCOG_ENV_TEST_SHELL=from-file\n")

      Rubycog::EnvFile.load([path])

      assert_equal 'from-shell', ENV['RUBYCOG_ENV_TEST_SHELL']
    end
  end

  def test_earlier_files_win_over_later_ones
    Dir.mktmpdir do |first|
      Dir.mktmpdir do |second|
        early = write_env(first, "RUBYCOG_ENV_TEST_ORDER=first\n")
        late = write_env(second, "RUBYCOG_ENV_TEST_ORDER=second\n")

        assert_equal [early, late], Rubycog::EnvFile.load([early, late])

        assert_equal 'first', ENV['RUBYCOG_ENV_TEST_ORDER']
      end
    end
  end

  def test_missing_files_are_skipped
    Dir.mktmpdir do |dir|
      present = write_env(dir, "RUBYCOG_ENV_TEST_PRESENT=1\n")
      absent = File.join(dir, 'nope.env')

      assert_equal [present], Rubycog::EnvFile.load([absent, present])
      assert_equal '1', ENV['RUBYCOG_ENV_TEST_PRESENT']
    end
  end

  def test_no_candidates_means_no_work
    Dir.mktmpdir do |dir|
      assert_empty Rubycog::EnvFile.load([File.join(dir, '.env')])
    end
  end

  def test_candidates_prefer_the_working_directory
    paths = Rubycog::EnvFile.paths(dir: '/work', root: '/checkout')

    assert_equal ['/work/.env', '/checkout/.env'], paths
  end

  def test_the_checkout_file_is_listed_once
    assert_equal ['/same/.env'], Rubycog::EnvFile.paths(dir: '/same', root: '/same')
  end

  def test_cli_loads_dotenv_before_configuring_providers
    order = []
    tui = Object.new
    tui.define_singleton_method(:run) {}

    Rubycog::EnvFile.stub(:load, -> { order << :dotenv; [] }) do
      Rubycog::Agent.stub(:configure, -> { order << :configure }) do
        Rubycog::Agent.stub(:new, ->(**_options) { Object.new }) do
          Rubycog::TUI.stub(:new, ->(*_args, **_options) { tui }) do
            assert_equal 0, Rubycog::CLI.start([])
          end
        end
      end
    end

    assert_equal %i[dotenv configure], order
  end

  def test_cli_reads_the_working_directory_dotenv
    Dir.mktmpdir do |dir|
      write_env(dir, "RUBYCOG_MODEL=dotenv-model\n")
      model = nil
      tui = Object.new
      tui.define_singleton_method(:run) {}

      Dir.chdir(dir) do
        Rubycog::Agent.stub(:new, ->(**_options) { Object.new }) do
          Rubycog::TUI.stub(:new, ->(*_args, **_options) { model = RubyLLM.config.default_model; tui }) do
            assert_equal 0, Rubycog::CLI.start([])
          end
        end
      end

      assert_equal 'dotenv-model', model
    end
  end

  private

  # Writes body as dir/.env and records every ENV name it mentions so teardown
  # can remove them again.
  def write_env(dir, body)
    (@keys ||= []).concat(body.scan(/RUBYCOG_\w+/))
    path = File.join(dir, '.env')
    File.write(path, body)
    path
  end

  def track(key, value)
    (@keys ||= []) << key
    ENV[key] = value
  end
end
