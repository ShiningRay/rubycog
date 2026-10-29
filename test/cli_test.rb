# frozen_string_literal: true

require_relative 'test_helper'
require 'stringio'

class CLITest < Minitest::Test
  def test_help
    output = StringIO.new
    assert_equal 0, Rubycog::CLI.start(['--help'], stdout: output)
    assert_includes output.string, '--model MODEL'
  end

  def test_invalid_option
    error = StringIO.new
    assert_equal 1, Rubycog::CLI.start(['--bad'], stderr: error)
    assert_includes error.string, 'invalid option'
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
end
