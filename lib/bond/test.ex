defmodule Bond.Test do
  @moduledoc """
  ExUnit helpers for asserting that Bond contract violations are raised.

  Each macro wraps the given expression in an `ExUnit.Assertions.assert_raise/2` that expects the
  matching Bond error struct — `Bond.PreconditionError`, `Bond.PostconditionError`,
  `Bond.CheckError`, or `Bond.InvariantError` — and optionally checks fields on the raised
  exception against a keyword of expected values. `Bond.Server`'s `@state_invariant` /
  `@transition_invariant` violations raise `Bond.InvariantError`, so `assert_invariant_violation/2`
  covers them too; pass `kind: :state_invariant` / `kind: :transition_invariant` to be specific.

  Field expectations may be exact values or `Regex` patterns. Regexes are matched against the
  string form of the field (the exception's `:expression` field is a string; the `:file` field
  is also a string). Any other expected value must be equal (via `==`) to the field's value.

  ## Usage

      defmodule MyAppTest do
        use ExUnit.Case
        use Bond.Test

        alias MyApp.Math

        test "rejects negative input" do
          assert_precondition_violation(Math.sqrt(-1), label: :non_negative_x)
        end

        test "rejects non-numeric input with a regex on the expression" do
          assert_precondition_violation(Math.sqrt("NaN"),
            label: :numeric_x,
            expression: ~r/is_number/
          )
        end

        test "postcondition violation when result is not a float" do
          assert_postcondition_violation(Math.sqrt(2, fn _ -> 10 end),
            module: MyApp.Math,
            function: {:sqrt, 2}
          )
        end
      end

  Each helper returns the raised exception struct so further assertions can be made on it:

      error = assert_precondition_violation(Math.sqrt(-1))
      assert error.binding[:x] == -1
  """

  @doc """
  Convenience: `use Bond.Test` is equivalent to `import Bond.Test`.
  """
  defmacro __using__(_opts) do
    quote do
      import Bond.Test
    end
  end

  @doc """
  Asserts that the given `call` raises a `Bond.PreconditionError`.

  Returns the raised exception struct. Optional `opts` is a keyword of expected field
  values (or `Regex` patterns) checked against the raised exception. See the module docs
  for the supported fields and matching rules.
  """
  defmacro assert_precondition_violation(call, opts \\ []) do
    assert_violation_ast(Bond.PreconditionError, call, opts)
  end

  @doc """
  Asserts that the given `call` raises a `Bond.PostconditionError`.

  See `assert_precondition_violation/2` for details.
  """
  defmacro assert_postcondition_violation(call, opts \\ []) do
    assert_violation_ast(Bond.PostconditionError, call, opts)
  end

  @doc """
  Asserts that the given `call` raises a `Bond.CheckError`.

  See `assert_precondition_violation/2` for details.
  """
  defmacro assert_check_violation(call, opts \\ []) do
    assert_violation_ast(Bond.CheckError, call, opts)
  end

  @doc """
  Asserts that the given `call` raises a `Bond.InvariantError`.

  See `assert_precondition_violation/2` for details.
  """
  defmacro assert_invariant_violation(call, opts \\ []) do
    assert_violation_ast(Bond.InvariantError, call, opts)
  end

  defp assert_violation_ast(exception_module, call, opts) do
    quote do
      error = ExUnit.Assertions.assert_raise(unquote(exception_module), fn -> unquote(call) end)

      Bond.Test.__verify_fields__(error, unquote(opts))
      error
    end
  end

  @doc false
  # Called from the macros above with the raised exception and the user's expectation keyword.
  # Public because it's referenced by quoted code that gets expanded in user modules.
  def __verify_fields__(error, opts) when is_list(opts) do
    Enum.each(opts, fn {key, expected} ->
      actual = Map.fetch!(error, key)

      unless field_matches?(expected, actual) do
        ExUnit.Assertions.flunk("""
        expected #{inspect(error.__struct__)} field #{inspect(key)} to match #{inspect(expected)}
        got: #{inspect(actual)}
        """)
      end
    end)

    :ok
  end

  defp field_matches?(%Regex{} = pattern, actual) when is_binary(actual) do
    Regex.match?(pattern, actual)
  end

  defp field_matches?(expected, actual), do: expected == actual
end
