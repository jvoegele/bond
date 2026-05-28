defmodule Bond.UnmatchedInvariantSubjectWarningTest do
  @moduledoc """
  Verifies the opt-out compile-time warning emitted when a public function in
  an invariant-declaring module has no clause that pattern-matches the
  struct — meaning invariants are silently skipped for that function.

  The warning is on by default; suppress with `use Bond,
  warn_unmatched_invariant_subject: false` per module or `config :bond,
  warn_unmatched_invariant_subject: false` globally.

  Static (non-warning) cases are exercised via real compiled fixtures in
  `test/support/bond_test/unmatched_invariant_subject.ex`. Warning-firing
  cases are compiled inside the test via `Code.compile_string/1` so the
  test suite itself doesn't grow real warnings.

  See also: the FAQ entry "Why isn't my invariant firing on this public
  function?" for the user-facing documentation.
  """

  use ExUnit.Case

  describe "static fixtures — should NOT warn" do
    test "fixture with `warn_unmatched_invariant_subject: false` compiled cleanly" do
      # If it had warned during normal compilation, mix test would have printed
      # the warning. This test is essentially a guard against regression: the
      # module exists and label/0 works, which is enough to prove the warning
      # mechanism honours the suppression option.
      assert BondTest.UnmatchedSubject.AllSuppressed.label() == "module label"
    end

    test "defp in an invariant-declaring module does not warn (defp is exempt)" do
      # Module compiles cleanly with no suppression: defp is exempt by design.
      assert BondTest.UnmatchedSubject.SilentDefp.matched(
               %BondTest.UnmatchedSubject.SilentDefp{value: 7}
             ) == 7
    end

    test "multi-clause def where ONE clause matches the struct does not warn" do
      # Mixed-match → at least one clause runs invariants. No footgun, no warn.
      assert %BondTest.UnmatchedSubject.MixedClauses{value: 3} =
               BondTest.UnmatchedSubject.MixedClauses.coerce(3)
    end
  end

  describe "warning emission via Code.compile_string/1" do
    test "fires for a public function with no struct-matching clause" do
      source = """
      defmodule BondTest.UnmatchedScratch.Warns do
        use Bond
        defstruct [:value]
        @invariant subject.value >= 0

        def label, do: "hello"
      end
      """

      diagnostics = capture_diagnostics(source)

      assert Enum.any?(diagnostics, fn d ->
               d.severity == :warning and
                 String.contains?(d.message, "label/0") and
                 String.contains?(d.message, "invariants are not checked here")
             end),
             "expected a warn-unmatched-invariant-subject diagnostic for label/0; got #{inspect(diagnostics)}"
    end

    test "warning message names the module and offers both suppression knobs" do
      source = """
      defmodule BondTest.UnmatchedScratch.MessageShape do
        use Bond
        defstruct [:value]
        @invariant subject.value >= 0

        def util(x), do: x
      end
      """

      diagnostics = capture_diagnostics(source)
      warning = Enum.find(diagnostics, &(&1.severity == :warning))

      assert warning, "expected at least one warning diagnostic"
      assert String.contains?(warning.message, "BondTest.UnmatchedScratch.MessageShape")
      assert String.contains?(warning.message, "use Bond, warn_unmatched_invariant_subject: false")
      assert String.contains?(warning.message, "config :bond, warn_unmatched_invariant_subject: false")
    end

    test "does NOT fire when `use Bond, warn_unmatched_invariant_subject: false` is set" do
      source = """
      defmodule BondTest.UnmatchedScratch.Suppressed do
        use Bond, warn_unmatched_invariant_subject: false
        defstruct [:value]
        @invariant subject.value >= 0

        def label, do: "hello"
      end
      """

      diagnostics = capture_diagnostics(source)

      refute Enum.any?(diagnostics, &(&1.severity == :warning)),
             "expected no diagnostics when suppression is on; got #{inspect(diagnostics)}"
    end

    test "does NOT fire when invariants are `:purge`d via use Bond" do
      # :purge means contracts are removed at compile time, so warning about
      # unfired invariants is moot — the user has explicitly opted out.
      source = """
      defmodule BondTest.UnmatchedScratch.Purged do
        use Bond, invariants: :purge
        defstruct [:value]
        @invariant subject.value >= 0

        def label, do: "hello"
      end
      """

      diagnostics = capture_diagnostics(source)

      refute Enum.any?(diagnostics, &(&1.severity == :warning)),
             "expected no diagnostics when invariants are purged; got #{inspect(diagnostics)}"
    end

    test "does NOT fire for a defp in an invariant-declaring module" do
      source = """
      defmodule BondTest.UnmatchedScratch.DefpOnly do
        use Bond
        defstruct [:value]
        @invariant subject.value >= 0

        def matched(%__MODULE__{} = s), do: s.value

        defp _helper(x), do: x

        def caller(%__MODULE__{} = s), do: _helper(s.value)
      end
      """

      diagnostics = capture_diagnostics(source)

      refute Enum.any?(diagnostics, &(&1.severity == :warning)),
             "expected no diagnostics for defp in invariant-declaring module; got #{inspect(diagnostics)}"
    end

    test "does NOT fire when at least one clause matches the struct" do
      source = """
      defmodule BondTest.UnmatchedScratch.MixedMatch do
        use Bond
        defstruct [:value]
        @invariant subject.value >= 0

        def coerce(%__MODULE__{} = s), do: s
        def coerce(v) when is_integer(v), do: %__MODULE__{value: v}
      end
      """

      diagnostics = capture_diagnostics(source)

      refute Enum.any?(diagnostics, &(&1.severity == :warning)),
             "expected no diagnostics for mixed-clause function; got #{inspect(diagnostics)}"
    end

    test "does NOT fire for a module with no @invariant declarations" do
      source = """
      defmodule BondTest.UnmatchedScratch.NoInvariants do
        use Bond
        defstruct [:value]

        def label, do: "hello"
      end
      """

      diagnostics = capture_diagnostics(source)

      refute Enum.any?(diagnostics, &(&1.severity == :warning)),
             "expected no diagnostics when module has no @invariant; got #{inspect(diagnostics)}"
    end
  end

  # Compiles `source` under Code.with_diagnostics/1, collecting any compile-
  # time diagnostics emitted (warnings or errors). Wraps the compile in a
  # try/rescue so an error-emitting source doesn't abort the test before the
  # diagnostics can be inspected.
  defp capture_diagnostics(source) do
    {_result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          Code.compile_string(source)
        rescue
          CompileError -> :compile_error
        end
      end)

    diagnostics
  end
end
