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
end
