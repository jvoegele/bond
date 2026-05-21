defmodule Bond.TestTest do
  @moduledoc """
  Tests for `Bond.Test` ExUnit helpers. Uses the existing `BondTest.Math` fixture as the
  module-under-test.
  """

  use ExUnit.Case
  use Bond.Test

  alias BondTest.Math

  describe "assert_precondition_violation/2" do
    test "passes when the expected precondition is raised" do
      error = assert_precondition_violation(Math.sqrt(-1))

      assert is_struct(error, Bond.PreconditionError)
      assert error.label == :non_negative_x
    end

    test "passes when expected fields match exactly" do
      assert_precondition_violation(Math.sqrt(-1),
        label: :non_negative_x,
        expression: "x >= 0",
        module: BondTest.Math,
        function: {:sqrt, 2}
      )
    end

    test "passes when expression is matched by a regex" do
      assert_precondition_violation(Math.sqrt("NaN"),
        label: :numeric_x,
        expression: ~r/is_number/
      )
    end

    test "fails when no precondition violation occurs" do
      assert_raise ExUnit.AssertionError, fn ->
        assert_precondition_violation(Math.sqrt(4))
      end
    end

    test "fails when expected field does not match" do
      assert_raise ExUnit.AssertionError, ~r/expected.*label.*to match :wrong_label/, fn ->
        assert_precondition_violation(Math.sqrt(-1), label: :wrong_label)
      end
    end

    test "returns the exception so further assertions can be made" do
      error = assert_precondition_violation(Math.sqrt(-1))
      assert error.binding[:x] == -1
    end
  end

  describe "assert_postcondition_violation/2" do
    test "passes when the expected postcondition is raised" do
      error = assert_postcondition_violation(Math.sqrt(2, fn _ -> 10 end))

      assert is_struct(error, Bond.PostconditionError)
      assert error.function == {:sqrt, 2}
    end

    test "fails when no postcondition violation occurs" do
      assert_raise ExUnit.AssertionError, fn ->
        assert_postcondition_violation(Math.sqrt(4))
      end
    end
  end
end
