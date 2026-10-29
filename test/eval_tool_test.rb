# frozen_string_literal: true

require_relative 'test_helper'

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
end
