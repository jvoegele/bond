defmodule Bond.NormCompatTest do
  @moduledoc """
  Verifies Bond's `Kernel.@/1` override coexists correctly with — and fails
  loudly when combined with — another library that also overrides `@/1`,
  using Norm as the real-world counterpart.

  Norm's `Norm.Contract` uses the IDENTICAL technique to Bond: `import Kernel,
  except: [@: 1]` followed by importing its own `@/1` clauses (a specific
  `@{:contract, _, expr}` clause plus a catch-all forwarding to `Kernel.@`).
  Since both libraries import `@/1` into the consumer's module at the same
  scope level, Elixir reports the call site as ambiguous — regardless of
  `use` ordering. This is a LOUD conflict (compile-time error pointing at
  the offending `@`-using line), not a silent dropped annotation.

  See "Can I use Bond and Norm in the same module?" in guides/faq.md for the
  user-facing documentation of this conflict and the split-modules workaround.

  Fixture source: `test/support/bond_test/norm_compat.ex`.
  """

  use ExUnit.Case

  describe "BondValidator standalone (use Bond + @pre)" do
    test "double/1 raises Bond.PreconditionError on negative input" do
      assert_raise Bond.PreconditionError, fn ->
        BondTest.NormCompat.BondValidator.double(-1)
      end
    end

    test "double/1 returns 2 * n on positive input" do
      assert BondTest.NormCompat.BondValidator.double(3) == 6
    end
  end

  describe "NormValidator standalone (use Norm + @contract)" do
    test "double/1 raises Norm.MismatchError on negative input" do
      assert_raise Norm.MismatchError, fn ->
        BondTest.NormCompat.NormValidator.double(-1)
      end
    end

    test "double/1 returns 2 * n on positive input" do
      assert BondTest.NormCompat.NormValidator.double(3) == 6
    end
  end

  describe "combining `use Bond` and `use Norm` in one module" do
    test "Norm-first / Bond-last ordering fails with ambiguous-import error" do
      source = """
      defmodule BondTest.NormCompat.NormFirstScratch do
        use Norm
        use Bond

        @pre is_integer(n) and n > 0
        def double(n), do: n * 2
      end
      """

      assert_ambiguous_at_compile_time(source)
    end

    test "Bond-first / Norm-last ordering fails with ambiguous-import error" do
      source = """
      defmodule BondTest.NormCompat.BondFirstScratch do
        use Bond
        use Norm

        def positive_int, do: spec(is_integer() and (&(&1 > 0)))

        @contract double(n :: positive_int()) :: positive_int()
        def double(n), do: n * 2
      end
      """

      assert_ambiguous_at_compile_time(source)
    end
  end

  # Asserts that compiling `source` fails with an ambiguous-import diagnostic
  # for `@/1`. Uses `Code.with_diagnostics/1` to capture structured diagnostics
  # (introduced in Elixir 1.15) rather than scraping stderr; the wrapped
  # `Code.compile_string/1` raises CompileError, which we rescue so the
  # test can inspect the diagnostics list afterwards.
  defp assert_ambiguous_at_compile_time(source) do
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          Code.compile_string(source)
        rescue
          CompileError -> :compile_error
        end
      end)

    assert result == :compile_error,
           "expected Code.compile_string/1 to raise CompileError; got #{inspect(result)}"

    assert Enum.any?(diagnostics, fn d ->
             d.severity == :error and
               String.contains?(d.message, "function @/1 imported from both") and
               String.contains?(d.message, "call is ambiguous")
           end),
           "expected an ambiguous-import diagnostic for @/1; got #{inspect(diagnostics)}"
  end
end
