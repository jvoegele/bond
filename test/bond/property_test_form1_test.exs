defmodule Bond.PropertyTest.Form1Test do
  @moduledoc """
  Tests for `Bond.PropertyTest.contract_holds/2` in its single-function (Form 1) shape.

  Property-test libraries are awkward to test from the outside because a failing property
  fails the surrounding test. So this file uses two strategies:

    1. **Passing-property tests** — drive a contracted function via `contract_holds` with
       a generator that satisfies the precondition. These run as real properties; if they
       ever fail, the test suite fails and we have a regression.

    2. **Underlying-mechanism tests** — exercise the same call path as the macro produces
       (contracted fn + random inputs that violate the precondition) using a plain
       `Enum.each` plus `assert_raise`. These confirm that Bond's runtime checks do fire
       under random input pressure, which is the property the macro relies on.

    3. **Macro-expansion test** — confirms the macro produces a `property` block AST
       calling `StreamData.fixed_list/1` and `apply/2` as documented.
  """

  use ExUnit.Case
  use Bond.PropertyTest

  alias BondTest.Math

  describe "contract_holds &Function/N (passing properties)" do
    contract_holds(&Math.sqrt/1, args: [StreamData.float(min: 0.0)])

    # Constrain both args to small floats so `:math.pow/2` doesn't overflow into
    # ArithmeticError (which would be a real error, not a contract violation, and would
    # fail this property for unrelated reasons).
    contract_holds(&Math.pow/2,
      args: [
        StreamData.float(min: 0.0, max: 10.0),
        StreamData.float(min: 0.0, max: 5.0)
      ],
      name: "Math.pow holds for small non-negative float bases and exponents"
    )
  end

  describe "underlying mechanism (Bond runtime catches random violations)" do
    test "Math.sqrt raises Bond.PreconditionError for any negative input" do
      assert_raise Bond.PreconditionError, fn ->
        StreamData.float(max: -0.0001)
        |> Enum.take(50)
        |> Enum.each(&Math.sqrt/1)
      end
    end

    test "Math.pow raises when a non-number is passed" do
      assert_raise Bond.PreconditionError, fn ->
        Math.pow("not a number", 2)
      end
    end
  end

  describe "macro expansion shape" do
    test "expands to a property block invoking StreamData.fixed_list and apply" do
      ast =
        quote do
          contract_holds(&Math.sqrt/1, args: [StreamData.float(min: 0.0)])
        end

      expanded =
        Macro.expand_once(ast, __ENV__)
        |> Macro.to_string()

      assert expanded =~ ~r"property\b"
      assert expanded =~ ~r"check\(?\s*all\(?\s*args <- StreamData\.fixed_list"
      assert expanded =~ ~r"apply\("
    end

    test "raises ArgumentError when :args option is missing" do
      assert_raise ArgumentError, fn ->
        Code.eval_quoted(
          quote do
            require Bond.PropertyTest
            Bond.PropertyTest.contract_holds(&Math.sqrt/1, [])
          end
        )
      end
    end
  end
end
