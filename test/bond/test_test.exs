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

  defmodule CheckFixture do
    @moduledoc false
    use Bond

    def must_be_positive(n) do
      check positive_n: n > 0
      n
    end
  end

  describe "assert_check_violation/2" do
    test "passes when the expected check is raised" do
      error = assert_check_violation(CheckFixture.must_be_positive(-1))

      assert is_struct(error, Bond.CheckError)
      assert error.label == :positive_n
    end

    test "passes when expected fields match exactly" do
      assert_check_violation(CheckFixture.must_be_positive(-1),
        label: :positive_n,
        expression: "n > 0"
      )
    end

    test "fails when no check violation occurs" do
      assert_raise ExUnit.AssertionError, fn ->
        assert_check_violation(CheckFixture.must_be_positive(1))
      end
    end
  end
end
