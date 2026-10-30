# frozen_string_literal: true

require_relative 'test_helper'
require 'stringio'
require 'minitest/mock'

class CLITest < Minitest::Test
  def test_help
    output = StringIO.new
    assert_equal 0, Rubycog::CLI.start(['--help'], stdout: output)
    assert_includes output.string, '--model MODEL'
    assert_includes output.string, '--yolo'
  end

  def test_invalid_option
    error = StringIO.new
    assert_equal 1, Rubycog::CLI.start(['--bad'], stderr: error)
    assert_includes error.string, 'invalid option'
  end

  def test_defaults_to_deepseek_flash
    Rubycog::Agent.configure(env: {})
    assert_equal 'deepseek-flash', RubyLLM.config.default_model
    assert_equal 'deepseek', RubyLLM.models.find('deepseek-flash').provider
  end

  def test_configures_providers_from_environment
    env = {
      'OPENAI_API_KEY' => 'test-key',
      'OLLAMA_API_BASE' => 'http://localhost:11434',
      'RUBYCOG_MODEL' => 'test-model'
    }
    Rubycog::Agent.configure(env: env)
    config = RubyLLM.config
    assert_equal 'test-key', config.openai_api_key
    assert_equal 'http://localhost:11434', config.ollama_api_base
    assert_equal 'test-model', config.default_model
  end

  def test_yolo_flag_reaches_the_tui
    captured = nil
    tui = Object.new
    tui.define_singleton_method(:run) {}

    Rubycog::Agent.stub(:new, ->(**_options) { Object.new }) do
      Rubycog::TUI.stub(:new, ->(_agent, yolo: false, history: [], session: nil, self_iteration: nil, argv: []) { captured = yolo; tui }) do
        assert_equal 0, Rubycog::CLI.start(['--yolo'])
      end
    end
    assert_equal true, captured
  end

  def test_yolo_is_off_by_default
    captured = nil
    tui = Object.new
    tui.define_singleton_method(:run) {}

    Rubycog::Agent.stub(:new, ->(**_options) { Object.new }) do
      Rubycog::TUI.stub(:new, ->(_agent, yolo: false, history: [], session: nil, self_iteration: nil, argv: []) { captured = yolo; tui }) do
        assert_equal 0, Rubycog::CLI.start([])
      end
    end
    assert_equal false, captured
  end

  def test_isolated_eval_flag_reaches_the_agent
    captured = nil
    tui = Object.new
    tui.define_singleton_method(:run) {}

    Rubycog::Agent.stub(:new, ->(**options) { captured = options; Object.new }) do
      Rubycog::TUI.stub(:new, ->(_agent, yolo: false, history: [], session: nil, self_iteration: nil, argv: []) { tui }) do
        assert_equal 0, Rubycog::CLI.start(['--isolated-eval'])
      end
    end

    assert_equal true, captured[:isolated_eval]
  end

  def test_display_name_defaults_to_rubycog
    Rubycog.name = nil
    assert_equal 'RubyCog', Rubycog.name
  end

  def test_name_flag_sets_the_display_name
    start_with(['--name', 'Coglet'])
    assert_equal 'Coglet', Rubycog.name
  ensure
    Rubycog.name = nil
  end

  def test_name_comes_from_the_environment_without_a_flag
    with_env(Rubycog::NAME_ENV, 'EnvCog') do
      start_with([])
      assert_equal 'EnvCog', Rubycog.name
    end
  end

  def test_name_flag_beats_the_environment
    with_env(Rubycog::NAME_ENV, 'EnvCog') do
      start_with(['--name', 'FlagCog'])
      assert_equal 'FlagCog', Rubycog.name
    end
  end

  def test_blank_name_falls_back_to_the_default
    start_with(['--name', '   '])
    assert_equal 'RubyCog', Rubycog.name
  end

  def test_name_drops_control_characters
    Rubycog.name = "Evil#{10.chr}Cog#{9.chr}"
    assert_equal 'EvilCog', Rubycog.name
  ensure
    Rubycog.name = nil
  end

  def test_help_lists_the_name_option
    output = StringIO.new
    assert_equal 0, Rubycog::CLI.start(['--help'], stdout: output)
    assert_includes output.string, '--name NAME'
  end

  private

  # Runs the real CLI with the agent and the curses UI stubbed out, so only the
  # option handling and the name resolution actually run.
  def start_with(argv)
    tui = Object.new
    tui.define_singleton_method(:run) {}
    Rubycog::Agent.stub(:new, ->(**_options) { Object.new }) do
      Rubycog::TUI.stub(:new, ->(_agent, yolo: false, history: [], session: nil, self_iteration: nil, argv: []) { tui }) do
        assert_equal 0, Rubycog::CLI.start(argv)
      end
    end
  end

  # Sets one environment variable for the block and restores both it and the
  # memoized display name afterwards, so tests cannot leak into each other.
  def with_env(key, value)
    previous = ENV.fetch(key, nil)
    ENV[key] = value
    yield
  ensure
    ENV[key] = previous
    Rubycog.name = nil
  end
end
