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

  describe "combining `use Norm` and `use Bond, at_syntax: false` in one module" do
    # The Combined fixture COMPILING is itself the proof that the ambiguous-import
    # conflict is gone — `at_syntax: false` leaves `@` to Norm and Bond contracts are
    # written as qualified `Bond.pre`/`Bond.post` calls.
    test "Bond's qualified contracts enforce in a module that also `use`s Norm" do
      assert BondTest.NormCompat.Combined.double(3) == 6
      assert_raise Bond.PreconditionError, fn -> BondTest.NormCompat.Combined.double(-1) end
    end

    test "Norm remains fully functional (spec/conform!) in the same module" do
      assert BondTest.NormCompat.Combined.conform_positive(5) == 5
      assert_raise Norm.MismatchError, fn -> BondTest.NormCompat.Combined.conform_positive(-1) end
    end

    test "the escape hatch removes the ambiguous-`@` error (Norm-first ordering)" do
      source = """
      defmodule BondTest.NormCompat.EscapeHatchScratch do
        use Norm
        use Bond, at_syntax: false

        Bond.pre is_integer(n) and n > 0
        def double(n), do: n * 2
      end
      """

      # Compiles cleanly — no ambiguous-import diagnostic for `@/1`.
      {result, diagnostics} =
        Code.with_diagnostics(fn ->
          try do
            Code.compile_string(source)
            :ok
          rescue
            e -> {:error, e}
          end
        end)

      assert result == :ok, "expected clean compile; got #{inspect(result)}"

      refute Enum.any?(diagnostics, &String.contains?(&1.message, "call is ambiguous")),
             "expected no ambiguous-`@` diagnostic; got #{inspect(diagnostics)}"
    after
      :code.purge(BondTest.NormCompat.EscapeHatchScratch)
      :code.delete(BondTest.NormCompat.EscapeHatchScratch)
    end

    # KNOWN LIMITATION: `at_syntax: false` fixes the `@`-syntax clash, but Norm's `@contract`
    # additionally rewrites function definitions (injecting a `defoverridable` + wrapper clause
    # via its own `@before_compile`). Bond's `@on_definition` observes those generated clauses,
    # so Bond's FSM sees the function defined twice and rejects it. This is a separate conflict
    # that the escape hatch does not resolve — same-function or even same-module use of Norm's
    # `@contract` alongside Bond still requires splitting into separate modules.
    test "Norm's @contract still conflicts with Bond's def-rewriting (documented limitation)" do
      source = """
      defmodule BondTest.NormCompat.ContractScratch do
        use Norm
        use Bond, at_syntax: false

        def positive_int, do: spec(is_integer() and (&(&1 > 0)))

        @contract triple(n :: positive_int()) :: positive_int()
        def triple(n), do: n * 3

        Bond.pre is_integer(n) and n > 0
        def double(n), do: n * 2
      end
      """

      assert_raise CompileError, fn -> Code.compile_string(source) end
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
