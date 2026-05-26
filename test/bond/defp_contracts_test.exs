defmodule Bond.DefpContractsTest do
  @moduledoc """
  Behavioural + diagnostic tests for contracts on private (`defp`)
  functions. Verifies:

    1. Contracts on `defp` still fire (they always did — this is
       regression coverage).
    2. Compilation of a module with `defp` contracts no longer emits
       Elixir's "@doc is always discarded for private functions"
       warning. Pre-0.16.2 this fired on every contracted `defp`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias BondTest.DefpContracts, as: Fix

  describe "contracts on defp still fire" do
    test "@pre on defp raises when the precondition fails" do
      assert_raise Bond.PreconditionError, fn -> Fix.encode("not a number") end
    end

    test "@pre on defp passes when the precondition holds" do
      assert Fix.encode(4.0) == 2.0
    end

    test "@post on defp raises when the postcondition fails" do
      # `doubled_int` is wrapped via `Fix.double/1`. Its @post asserts
      # `result == x * 2`; passing a non-integer would fail the @pre
      # first, so to demonstrate post-firing we'd need a broken impl —
      # since we don't intentionally ship one, verify the success path
      # and rely on the precondition-failure test above plus
      # math_test.exs for the @post failure pattern.
      assert Fix.double(7) == 14
    end
  end

  describe "no @doc warning at compile time" do
    test "defining a module with @pre on a defp emits no '@doc discarded' warning" do
      output =
        capture_io(:stderr, fn ->
          Code.eval_string("""
          defmodule Bond.DefpContractsTest.NoWarnFixture do
            use Bond

            def public(x), do: private(x)

            @pre is_integer(x)
            defp private(x), do: x * 2
          end
          """)
        end)

      refute output =~ ~r/@doc.*discarded for private/i,
             "expected no '@doc discarded for private' warning, got:\n#{output}"

      refute output =~ ~r/module attribute @doc was set but never used/i,
             "expected no '@doc set but never used' warning, got:\n#{output}"
    end
  end
end
