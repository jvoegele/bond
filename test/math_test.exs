defmodule BondTest.MathTest do
  @moduledoc """
  Test the `BondTest.Math` module defined in `test/support/bond_test/math.ex`.
  """

  use ExUnit.Case
  use ExUnitProperties

  alias Bond.PostconditionError
  alias Bond.PreconditionError
  alias BondTest.Math

  describe "sqrt/1" do
    test "when given 0, returns 0.0" do
      assert Math.sqrt(0) === 0.0
      assert Math.sqrt(0.0) === 0.0
    end

    test "when given 1, returns 1.0" do
      assert Math.sqrt(1) === 1.0
      assert Math.sqrt(1.0) === 1.0
    end

    property "when given a positive number, returns the square root of that number" do
      check all float_val <- float(min: 1.00001),
                int_val <- integer(2..1_000_000) do
        assert Math.sqrt(float_val) == :math.sqrt(float_val)
        assert Math.sqrt(float_val) < float_val
        assert Math.sqrt(int_val) == :math.sqrt(int_val)
        assert Math.sqrt(int_val) < int_val
      end
    end

    test "raises PreconditionError when given a non-numeric value" do
      error = assert_raise PreconditionError, fn -> Math.sqrt("NaN") end

      assert is_exception(error)
      assert is_struct(error, PreconditionError)
      assert Exception.message(error) =~ ~r{precondition failed for call to.*sqrt/2}

      assert error.label == :numeric_x
    end

    test "raises PreconditionError exception when given a negative number" do
      error = assert_raise PreconditionError, fn -> Math.sqrt(-1) end

      assert is_exception(error)
      assert is_struct(error, PreconditionError)
      assert Exception.message(error) =~ ~r{precondition failed for call to.*sqrt/2}

      assert error.label == :non_negative_x
      assert error.expression == "x >= 0"
      assert %Bond.Env{} = assertion_env = error.assertion_env
      assert assertion_env.module == BondTest.Math
      assert is_nil(assertion_env.function)
      assert assertion_env.file =~ ~r{/bond_test/math.ex$}

      assert %Bond.Env{} = function_env = error.function_env
      assert function_env.module == BondTest.Math
      assert function_env.function == {:sqrt, 2}

      assert function_env.module == assertion_env.module
      assert function_env.file == assertion_env.file
      assert function_env.line > assertion_env.line
    end

    test "raises PostconditionError when result is not a float" do
      error = assert_raise PostconditionError, fn -> Math.sqrt(2, fn _ -> 10 end) end
      assert is_exception(error)
      assert is_struct(error, PostconditionError)
      assert Exception.message(error) =~ ~r{postcondition failed in .*sqrt/2}
    end

    test "does not swallow exceptions" do
      assert_raise RuntimeError, "KABOOM!", fn -> Math.sqrt(42, fn _ -> raise "KABOOM!" end) end
    end
  end

  describe "pow/2" do
    test "raises `x` to the `y` power" do
      assert Math.pow(2, 3) == :math.pow(2, 3)
    end
  end
end
