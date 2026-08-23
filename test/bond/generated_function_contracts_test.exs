defmodule Bond.GeneratedFunctionContractsTest do
  @moduledoc """
  Contracts written on a function whose name is wrapped in double underscores.

  Bond does not weave those (#105) — the convention marks a compiler- or library-generated
  function, and weaving into them is what made `@invariant` unusable on an `Ecto.Schema`
  module. But pending contracts live in the compile-state FSM until a definition absorbs them,
  so simply declining to weave leaves them queued for whatever the module defines *next*. This
  covers both halves: the contract is taken away from the function it cannot be applied to, and
  it does not reappear on the following one.

  `guides/stability.md` treats a behaviour change to the intercepted attribute syntax as
  something that must not happen silently, which is why the discard warns.
  """

  use ExUnit.Case, async: true

  alias BondTest.Diagnostics

  describe "a contract declared on a hand-written __name__ function" do
    test "is discarded rather than applied, and says so" do
      warnings =
        Diagnostics.warnings("""
        defmodule Bond.GeneratedFunctionContractsTest.Warned do
          use Bond

          @pre must_be_positive: x > 0
          def __custom__(x), do: {:custom, x}
        end
        """)

      assert warnings =~ "1 precondition declared on `__custom__/1` was discarded"
      assert warnings =~ "rename it without the leading and trailing underscores"
    end

    test "does not reappear on the next function defined" do
      # The failure this guards against is silent: with the contract still queued, `bar/1`
      # acquires a precondition its author never wrote, and — because the parameter names line
      # up — enforces it without any error to say where it came from.
      [{module, _} | _] =
        Code.compile_string("""
        defmodule Bond.GeneratedFunctionContractsTest.NoLeak do
          use Bond

          @pre must_be_positive: x > 0
          def __custom__(x), do: {:custom, x}

          def bar(x), do: {:bar, x}
        end
        """)

      assert module.__custom__(-5) == {:custom, -5}
      assert module.bar(-5) == {:bar, -5}
    after
      :code.purge(Bond.GeneratedFunctionContractsTest.NoLeak)
      :code.delete(Bond.GeneratedFunctionContractsTest.NoLeak)
    end

    test "counts both kinds and pluralises" do
      warnings =
        Diagnostics.warnings("""
        defmodule Bond.GeneratedFunctionContractsTest.Both do
          use Bond

          @pre a: x > 0
          @pre b: x < 100
          @post c: is_tuple(result)
          def __custom__(x), do: {:custom, x}
        end
        """)

      assert warnings =~ "2 preconditions and 1 postcondition declared on `__custom__/1` were"
    end
  end

  describe "implicitly generated functions are left alone" do
    test "a @pre above the first function using %__MODULE__{} still applies to that function" do
      # `defstruct` emits `__struct__/0` while the *first* `%__MODULE__{}` is expanded, which
      # here is inside `set/2` — a function this `@pre` is written for. The discard selects by
      # line for exactly this reason: `__struct__/0` carries the `defstruct` line, above the
      # contract, so it takes nothing. Dropping everything pending instead silently disarmed
      # contracts across the whole suite.
      [{module, _} | _] =
        Code.compile_string("""
        defmodule Bond.GeneratedFunctionContractsTest.StructTiming do
          use Bond

          defstruct n: 0

          @pre in_range: v >= 0
          def set(%__MODULE__{} = s, v), do: %{s | n: v}
        end
        """)

      good = struct!(module, n: 0)
      assert module.set(good, 5).n == 5
      assert_raise Bond.PreconditionError, fn -> module.set(good, -1) end
    after
      :code.purge(Bond.GeneratedFunctionContractsTest.StructTiming)
      :code.delete(Bond.GeneratedFunctionContractsTest.StructTiming)
    end

    test "a struct module with an invariant compiles without a discard warning" do
      warnings =
        Diagnostics.warnings("""
        defmodule Bond.GeneratedFunctionContractsTest.Quiet do
          use Bond

          defstruct n: 0

          @invariant non_negative: subject.n >= 0

          def bump(%__MODULE__{} = s), do: %{s | n: s.n + 1}
        end
        """)

      refute warnings =~ "discarded"
    end
  end
end
