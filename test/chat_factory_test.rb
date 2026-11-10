# frozen_string_literal: true

require_relative 'test_helper'

# Covers the chat options that let RubyCog talk to a private OpenAI-compatible
# gateway whose model ids are absent from RubyLLM's registry.
class ChatFactoryTest < Minitest::Test
  def test_no_model_and_no_env_asks_for_nothing
    assert_empty Rubycog::ChatFactory.options(model: nil, env: {})
  end

  def test_a_model_is_passed_through
    assert_equal({ model: 'gpt-4o-mini' }, Rubycog::ChatFactory.options(model: 'gpt-4o-mini', env: {}))
  end

  def test_a_named_provider_implies_the_model_exists
    options = Rubycog::ChatFactory.options(model: 'auto/deepseek-v4.1-flash',
                                           env: { 'RUBYCOG_PROVIDER' => 'openai' })

    assert_equal :openai, options[:provider]
    assert_equal 'auto/deepseek-v4.1-flash', options[:model]
    assert_equal true, options[:assume_model_exists]
  end

  def test_the_assume_flag_works_without_a_provider
    options = Rubycog::ChatFactory.options(model: 'private-model',
                                           env: { 'RUBYCOG_ASSUME_MODEL_EXISTS' => '1' })

    assert_equal true, options[:assume_model_exists]
    refute options.key?(:provider)
  end

  def test_blank_provider_is_ignored
    options = Rubycog::ChatFactory.options(model: 'x', env: { 'RUBYCOG_PROVIDER' => '  ' })

    refute options.key?(:provider)
    refute options.key?(:assume_model_exists)
  end
end
