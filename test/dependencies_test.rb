# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# A gem added to the Gemfile but never installed used to abort /restart inside
# rubygems, losing the session with nothing but a backtrace.
#
# These tests pin the guard rails: the restart probe names the missing gem, the
# restarted process drops bundler's RUBYOPT preload, the entry point starts from
# an unrelated directory and explains a broken bundle, and the gemspec, Gemfile
# and lock file cannot drift apart unnoticed.
class DependenciesTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  ENTRY = File.join(ROOT, 'bin', 'rubycog')

  # Builds a Gemfile whose locked gem is not installed, so bundler fails fast
  # and offline the same way it would after a forgotten `bundle install`.
  def broken_bundle
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "source 'https://rubygems.org'\ngem 'no_such_gem_xyz'\n")
      File.write(File.join(dir, 'Gemfile.lock'), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            no_such_gem_xyz (1.0.0)

        PLATFORMS
          ruby

        DEPENDENCIES
          no_such_gem_xyz
      LOCK
      yield File.join(dir, 'Gemfile')
    end
  end

  def run_entry(dir, *args, env: {})
    out, status = Open3.capture2e({ 'RUBYOPT' => nil, 'BUNDLER_SETUP' => nil, 'BUNDLE_GEMFILE' => nil }
                                    .merge(env),
                                  RbConfig.ruby, ENTRY, *args, chdir: dir)
    [out, status.exitstatus]
  end

  def test_restart_problem_names_the_gem_that_is_not_installed
    broken_bundle do |gemfile|
      problem = Rubycog::TUI.new(FakeChat.new).send(:restart_problem, gemfile: gemfile)

      refute_nil problem
      assert_includes problem, 'no_such_gem_xyz'
    end
  end

  def test_restart_problem_is_nil_when_the_bundle_loads
    assert_nil Rubycog::TUI.new(FakeChat.new).send(:restart_problem)
  end

  def test_restart_env_drops_the_bundler_preload_and_pins_the_gemfile
    with_env('RUBYOPT' => '-rbundler/setup -E UTF-8', 'BUNDLER_SETUP' => '/gems/bundler/setup',
             'BUNDLE_GEMFILE' => nil) do
      env = Rubycog::TUI.new(FakeChat.new).send(:restart_env)

      assert_nil env['BUNDLER_SETUP']
      refute_includes env['RUBYOPT'].to_s, 'bundler/setup'
      assert_includes env['RUBYOPT'].to_s, '-E UTF-8'
      assert_equal File.join(ROOT, 'Gemfile'), env['BUNDLE_GEMFILE']
    end
  end

  def test_restart_env_unsets_rubyopt_when_only_the_preload_was_present
    with_env('RUBYOPT' => '-rbundler/setup', 'BUNDLE_GEMFILE' => nil) do
      assert_nil Rubycog::TUI.new(FakeChat.new).send(:restart_env)['RUBYOPT']
    end
  end

  def test_entry_point_starts_from_an_unrelated_directory
    broken_bundle do |gemfile|
      out, status = run_entry(File.dirname(gemfile), '--version')

      assert_equal 0, status, out
      assert_equal Rubycog::VERSION, out.strip
    end
  end

  def test_entry_point_explains_a_broken_bundle_instead_of_a_backtrace
    broken_bundle do |gemfile|
      out, status = run_entry(File.dirname(gemfile), '--version',
                              env: { 'BUNDLE_GEMFILE' => gemfile })

      assert_equal 1, status
      assert_includes out, 'the bundle is not installed'
      assert_includes out, 'no_such_gem_xyz'
      refute_match(/\.rb:\d+:in /, out)
    end
  end

  def test_entry_point_still_parses
    out, status = Open3.capture2e(RbConfig.ruby, '-c', ENTRY)

    assert status.success?, out
  end

  def test_gemspec_runtime_dependencies_reach_the_gemfile_and_lock
    spec = Gem::Specification.load(File.join(ROOT, 'rubycog.gemspec'))
    gemfile = File.read(File.join(ROOT, 'Gemfile'))
    lock = File.read(File.join(ROOT, 'Gemfile.lock'))
    names = spec.runtime_dependencies.map(&:name)

    refute_empty names
    names.each do |name|
      assert_match(/^\s*gem '#{Regexp.escape(name)}'/, gemfile, "#{name} is missing from the Gemfile")
      assert_match(/^ {4}#{Regexp.escape(name)} \(/, lock, "#{name} is missing from Gemfile.lock")
    end
  end

  private

  def with_env(pairs)
    before = pairs.keys.to_h { |key| [key, ENV[key]] }
    pairs.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    before.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
