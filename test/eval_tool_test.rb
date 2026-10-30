# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

class EvalToolTest < Minitest::Test
  def setup
    @tool = Rubycog::EvalTool.new
  end

  def test_has_the_exact_tool_name_and_requires_approval
    assert_equal 'eval', @tool.name
    assert @tool.requires_approval?
    parameter = @tool.declared_parameters.fetch(:code)
    assert_equal :string, parameter.type
    assert parameter.required
  end

  def test_evaluates_ruby_and_returns_inspection
    assert_equal '42', @tool.execute(code: '6 * 7')
    assert_equal '"hello"', @tool.execute(code: '"hello"')
    assert_equal '[1, 4, 9]', @tool.execute(code: '[1, 2, 3].map { |n| n**2 }')
  end

  def test_preserves_local_variables_between_calls
    @tool.execute(code: 'answer = 40')
    assert_equal '42', @tool.execute(code: 'answer + 2')
  end

  def test_returns_runtime_and_syntax_errors_to_the_model
    assert_match(/\AZeroDivisionError: /, @tool.execute(code: '1 / 0'))
    assert_match(/\ASyntaxError: /, @tool.execute(code: 'def'))
  end

  def test_returns_load_errors_to_the_model
    assert_match(/\ALoadError: /, @tool.execute(code: "require 'rubycog_missing_dependency'"))
  end

  def test_require_relative_resolves_from_the_given_base_dir
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'rubycog_eval_helper.rb'), 'RUBYCOG_EVAL_HELPER_LOADED = true')
      tool = Rubycog::EvalTool.new(base_dir: dir)

      assert_equal 'true',
        tool.execute(code: "require_relative 'rubycog_eval_helper'; RUBYCOG_EVAL_HELPER_LOADED")
    end
  end

  def test_missing_require_relative_is_returned_instead_of_escaping
    assert_match(/\ALoadError: /, @tool.execute(code: "require_relative 'rubycog_missing_relative'"))
  end

  def test_exit_is_returned_instead_of_terminating_the_process
    assert_match(/\ASystemExit: /, @tool.execute(code: 'exit 7'))
  end

  def test_interrupt_is_not_swallowed
    assert_raises(Interrupt) { @tool.execute(code: 'raise Interrupt') }
  end

  def test_isolated_mode_drops_locals_between_calls
    tool = Rubycog::EvalTool.new(keep_locals: false)
    tool.execute(code: 'isolated_marker = 1')

    assert_equal 'false', tool.execute(code: 'defined?(isolated_marker) ? true : false')
  end

  def test_reset_drops_persistent_locals
    @tool.execute(code: 'reset_marker = 1')
    @tool.reset

    assert_equal 'false', @tool.execute(code: 'defined?(reset_marker) ? true : false')
  end

  def test_keep_locals_is_on_by_default
    assert @tool.keep_locals?
  end
end
