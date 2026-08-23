defmodule Bond.PreconditionAvailabilityTest do
  @moduledoc """
  #92 — Meyer's Precondition Availability rule, as a compile-time warning.

  A precondition is an obligation on the *caller*, so it must not be stated in terms the
  caller cannot reach. In Elixir that reduces to: a public function's `@pre` should not
  call a private function of the same module.

  Uses `BondTest.Diagnostics` rather than a stderr capture — see #86 for why a global
  capture makes these assertions racy in an async module.
  """

  use ExUnit.Case, async: true

  defp availability_warnings(source) do
    source
    |> BondTest.Diagnostics.capture()
    |> Enum.filter(&(&1.message =~ "Precondition Availability"))
  end

  defp warns?(source), do: availability_warnings(source) != []

  describe "fires when a public precondition calls a private predicate" do
    test "the basic case" do
      assert warns?("""
             defmodule BondTest.AvailScratch.Basic do
               use Bond
               @pre valid: ok?(x)
               def run(x), do: x
               defp ok?(v), do: is_integer(v)
             end
             """)
    end

    test "the message names the offending function and the rule" do
      [%{message: message}] =
        availability_warnings("""
        defmodule BondTest.AvailScratch.Message do
          use Bond
          @pre valid: ok?(x)
          def run(x), do: x
          defp ok?(v), do: is_integer(v)
        end
        """)

      assert message =~ "`ok?/1`"
      assert message =~ "run/1"
      assert message =~ "Precondition Availability rule"
      assert message =~ "@bond_warn_unavailable_preconditions false"
    end

    test "names every private predicate a precondition calls, in one warning" do
      [%{message: message}] =
        availability_warnings("""
        defmodule BondTest.AvailScratch.Several do
          use Bond
          @pre valid: ok?(x) and fine?(x)
          def run(x), do: x
          defp ok?(v), do: is_integer(v)
          defp fine?(v), do: v > 0
        end
        """)

      assert message =~ "`ok?/1`"
      assert message =~ "`fine?/1`"
    end

    test "distinguishes arities" do
      assert warns?("""
             defmodule BondTest.AvailScratch.Arity do
               use Bond
               @pre valid: ok?(x, 10)
               def run(x), do: x
               def ok?(v), do: is_integer(v)
               defp ok?(v, limit), do: v < limit
             end
             """)
    end
  end

  describe "fires when a public precondition calls a `@doc false` public predicate (#110)" do
    test "the basic case" do
      assert warns?("""
             defmodule BondTest.AvailScratch.HiddenBasic do
               use Bond
               @doc false
               def ok?(v), do: is_integer(v)
               @pre valid: ok?(x)
               def run(x), do: x
             end
             """)
    end

    test "the message says hidden-from-docs, not private" do
      # The fix differs — a private predicate is made public, a hidden one has its
      # `@doc false` removed — so the two must not share wording.
      [%{message: message}] =
        availability_warnings("""
        defmodule BondTest.AvailScratch.HiddenMessage do
          use Bond
          @doc false
          def ok?(v), do: is_integer(v)
          @pre valid: ok?(x)
          def run(x), do: x
        end
        """)

      assert message =~ "`ok?/1`"
      assert message =~ "public but hidden from the generated docs by `@doc false`"
      assert message =~ "Remove the `@doc false`"
      refute message =~ "a private function (`ok?/1`)"
    end

    test "reports a private and a hidden predicate in one warning, each with its own wording" do
      [%{message: message}] =
        availability_warnings("""
        defmodule BondTest.AvailScratch.HiddenAndPrivate do
          use Bond
          @doc false
          def shown?(v), do: is_integer(v)
          @pre valid: shown?(x) and secret?(x)
          def run(x), do: x
          defp secret?(v), do: v > 0
        end
        """)

      assert message =~ "a private function (`secret?/1`)"
      assert message =~ "(`shown?/1`) that is public but hidden"
    end

    test "the last @doc wins, matching Elixir" do
      refute warns?("""
             defmodule BondTest.AvailScratch.HiddenThenShown do
               use Bond
               @doc false
               @doc "actually documented"
               def ok?(v), do: is_integer(v)
               @pre valid: ok?(x)
               def run(x), do: x
             end
             """)
    end
  end

  describe "the documentation argument is not applied where nothing is published (#110)" do
    test "a caller that is itself @doc false publishes no obligation, so hidden is not reported" do
      refute warns?("""
             defmodule BondTest.AvailScratch.HiddenCaller do
               use Bond
               @doc false
               def ok?(v), do: is_integer(v)
               @doc false
               @pre valid: ok?(x)
               def run(x), do: x
             end
             """)
    end

    test "but a private call still is — Meyer's rule is about callability, not publication" do
      assert warns?("""
             defmodule BondTest.AvailScratch.HiddenCallerPrivateCall do
               use Bond
               @doc false
               @pre valid: ok?(x)
               def run(x), do: x
               defp ok?(v), do: is_integer(v)
             end
             """)
    end
  end

  describe "stays silent where the rule does not apply" do
    test "an undocumented public predicate still appears in the docs" do
      # Absence of `@doc` is not `@doc false`: ExDoc lists the function either way.
      refute warns?("""
             defmodule BondTest.AvailScratch.Undocumented do
               use Bond
               def ok?(v), do: is_integer(v)
               @pre valid: ok?(x)
               def run(x), do: x
             end
             """)
    end

    test "a public predicate is available to callers" do
      refute warns?("""
             defmodule BondTest.AvailScratch.PublicPredicate do
               use Bond
               @pre valid: ok?(x)
               def run(x), do: x
               def ok?(v), do: is_integer(v)
             end
             """)
    end

    test "postconditions are exempt — the function's promise, not the caller's obligation" do
      refute warns?("""
             defmodule BondTest.AvailScratch.Postcondition do
               use Bond
               @post valid: ok?(result)
               def run(x), do: x
               defp ok?(v), do: is_integer(v)
             end
             """)
    end

    test "a private function's own precondition — its only clients are in this module" do
      refute warns?("""
             defmodule BondTest.AvailScratch.PrivateFunction do
               use Bond
               @pre valid: ok?(x)
               defp run(x), do: x
               defp ok?(v), do: is_integer(v)
               def public(x), do: run(x)
             end
             """)
    end

    test "kernel guards and operators are not private calls" do
      refute warns?("""
             defmodule BondTest.AvailScratch.Kernel do
               use Bond
               @pre valid: is_integer(x) and x > 0
               def run(x), do: x
               defp unrelated(v), do: v
             end
             """)
    end

    test "a remote call cannot reach a private function" do
      refute warns?("""
             defmodule BondTest.AvailScratch.Remote do
               use Bond
               @pre valid: String.valid?(x)
               def run(x), do: x
               defp valid?(v), do: v
             end
             """)
    end

    test "purged preconditions leave no contract for a caller to satisfy" do
      refute warns?("""
             defmodule BondTest.AvailScratch.Purged do
               use Bond, preconditions: :purge, postconditions: :purge, invariants: :purge
               @pre valid: ok?(x)
               def run(x), do: x
               defp ok?(v), do: is_integer(v)
             end
             """)
    end
  end

  describe "suppression" do
    test "per function, via @bond_warn_unavailable_preconditions false" do
      refute warns?("""
             defmodule BondTest.AvailScratch.SuppressedFunction do
               use Bond
               @bond_warn_unavailable_preconditions false
               @pre valid: ok?(x)
               def run(x), do: x
               defp ok?(v), do: is_integer(v)
             end
             """)
    end

    test "per function, scoped to the next def only" do
      warnings =
        availability_warnings("""
        defmodule BondTest.AvailScratch.SuppressedScope do
          use Bond
          @bond_warn_unavailable_preconditions false
          @pre valid: ok?(x)
          def suppressed(x), do: x

          @pre valid: ok?(x)
          def not_suppressed(x), do: x

          defp ok?(v), do: is_integer(v)
        end
        """)

      assert length(warnings) == 1
      assert hd(warnings).message =~ "not_suppressed/1"
    end

    test "per module, via use Bond" do
      refute warns?("""
             defmodule BondTest.AvailScratch.SuppressedModule do
               use Bond, warn_unavailable_preconditions: false
               @pre valid: ok?(x)
               def run(x), do: x
               defp ok?(v), do: is_integer(v)
             end
             """)
    end
  end
end
