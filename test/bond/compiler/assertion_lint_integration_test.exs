defmodule Bond.Compiler.AssertionLintIntegrationTest do
  @moduledoc """
  Integration test for wiring the assertion linter (#52) into the compiler: `Assertion.new/5` —
  the single funnel every assertion kind flows through — runs the linter and emits `IO.warn`
  diagnostics, guarded by the `:lint_assertions` compile-time config. Pure detection is covered
  by `Bond.Compiler.LinterTest`; this pins the side-effecting hook and the toggle.

  `async: false` because it mutates application env.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO, only: [with_io: 2]

  alias Bond.Compiler.Assertion

  setup do
    original = Application.fetch_env(:bond, :lint_assertions)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:bond, :lint_assertions, value)
        :error -> Application.delete_env(:bond, :lint_assertions)
      end
    end)

    :ok
  end

  # Build an assertion through the real funnel, returning `{struct, stderr_output}`.
  defp new_with_io(expression) do
    with_io(:stderr, fn -> Assertion.new(:pre, :label, expression, __ENV__) end)
  end

  test "Assertion.new emits a linter warning for a vacuous assertion when enabled" do
    Application.put_env(:bond, :lint_assertions, true)

    {_struct, output} = new_with_io(quote(do: 1 == 1))

    assert output =~ "Bond assertion linter"
    assert output =~ "always `true`"
  end

  test "Assertion.new stays silent for a meaningful assertion" do
    Application.put_env(:bond, :lint_assertions, true)

    assert {_struct, ""} = new_with_io(quote(do: x > 0))
  end

  test "the :lint_assertions config toggle silences the linter" do
    Application.put_env(:bond, :lint_assertions, false)

    assert {_struct, ""} = new_with_io(quote(do: 1 == 1))
  end

  test "linting never alters the produced assertion struct" do
    Application.put_env(:bond, :lint_assertions, true)

    {struct, _output} = new_with_io(quote(do: 1 == 1))

    assert %Assertion{kind: :pre, label: :label, code: "1 == 1"} = struct
  end
end
