defmodule Bond.SkippedInvariantsWarningTest do
  @moduledoc """
  Verifies the opt-out compile-time warning emitted when a public function in
  an invariant-declaring module has no clause that pattern-matches the
  struct — meaning invariants are silently skipped for that function.

  Suppression is layered. From narrowest to broadest:

    * per-function: `@bond_warn_skipped_invariants false` (next def only)
    * per-module:   `use Bond, warn_skipped_invariants: false`
    * global:       `config :bond, warn_skipped_invariants: false`

  Default at every layer is `true`. Per-function override (when set) wins
  over the module/global value for that single function.

  Static (non-warning) cases are exercised via real compiled fixtures in
  `test/support/bond_test/skipped_invariants.ex`. Warning-firing cases are
  compiled inside the test via `Code.compile_string/1` so the test suite
  itself doesn't grow real warnings.

  See also: the FAQ entry "Why is Bond warning that my function 'matched no
  struct parameter'?" for the user-facing documentation.
  """

  use ExUnit.Case

  describe "static fixtures — should NOT warn" do
    test "module-wide `use Bond, warn_skipped_invariants: false` compiled cleanly" do
      assert BondTest.SkippedInvariants.AllSuppressed.label() == "module label"
    end

    test "per-function `@bond_warn_skipped_invariants false` compiled cleanly" do
      # class_name/0 has the per-function suppression. push/2 matches the struct
      # so it never triggers the warning. Module compiles silently.
      assert BondTest.SkippedInvariants.PerFunctionSuppressed.class_name() == "stack"

      stack = %BondTest.SkippedInvariants.PerFunctionSuppressed{items: []}
      assert %{items: [:a]} = BondTest.SkippedInvariants.PerFunctionSuppressed.push(stack, :a)
    end

    test "defp in an invariant-declaring module does not warn (defp is exempt)" do
      # Module compiles cleanly with no suppression: defp is exempt by design.
      assert BondTest.SkippedInvariants.SilentDefp.matched(%BondTest.SkippedInvariants.SilentDefp{
               value: 7
             }) == 7
    end

    test "multi-clause def where ONE clause matches the struct does not warn" do
      # Mixed-match → at least one clause runs invariants. No footgun, no warn.
      assert %BondTest.SkippedInvariants.MixedClauses{value: 3} =
               BondTest.SkippedInvariants.MixedClauses.coerce(3)
    end

    test "constructors that return %__MODULE__{...} or {:ok, %__MODULE__{...}} do not warn" do
      # The post-invariant check fires at runtime on the returned struct, so
      # invariants ARE checked for these functions — Bond's static heuristic
      # detects the struct return shape and skips the warning. No per-function
      # suppression needed.
      assert %BondTest.SkippedInvariants.ConstructorReturnsStruct{n: 3} =
               BondTest.SkippedInvariants.ConstructorReturnsStruct.new(3)

      assert {:ok, %BondTest.SkippedInvariants.ConstructorReturnsStruct{n: 3}} =
               BondTest.SkippedInvariants.ConstructorReturnsStruct.try_new(3)

      # And the error-returning clause runs fine — its post-check is a runtime
      # no-op (return value isn't a struct), but invariants fire on the OK
      # clause, so the function as a whole has an active check path.
      assert {:error, :invalid} =
               BondTest.SkippedInvariants.ConstructorReturnsStruct.try_new(-1)
    end
  end

  describe "warning emission via Code.compile_string/1" do
    test "fires for a public function with no struct-matching clause" do
      source = """
      defmodule BondTest.SkippedScratch.Warns do
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
                 String.contains?(d.message, "invariants are skipped here")
             end),
             "expected a warn-skipped-invariants diagnostic for label/0; got #{inspect(diagnostics)}"
    end

    test "warning message names the module and offers all three suppression knobs" do
      source = """
      defmodule BondTest.SkippedScratch.MessageShape do
        use Bond
        defstruct [:value]
        @invariant subject.value >= 0

        def util(x), do: x
      end
      """

      diagnostics = capture_diagnostics(source)
      warning = Enum.find(diagnostics, &(&1.severity == :warning))

      assert warning, "expected at least one warning diagnostic"
      assert String.contains?(warning.message, "BondTest.SkippedScratch.MessageShape")
      assert String.contains?(warning.message, "@bond_warn_skipped_invariants false")
      assert String.contains?(warning.message, "use Bond, warn_skipped_invariants: false")
      assert String.contains?(warning.message, "config :bond, warn_skipped_invariants: false")
    end

    test "does NOT fire when `use Bond, warn_skipped_invariants: false` is set (per-module)" do
      source = """
      defmodule BondTest.SkippedScratch.ModuleSuppressed do
        use Bond, warn_skipped_invariants: false
        defstruct [:value]
        @invariant subject.value >= 0

        def label, do: "hello"
      end
      """

      diagnostics = capture_diagnostics(source)

      refute Enum.any?(diagnostics, &(&1.severity == :warning)),
             "expected no diagnostics when module-level suppression is on; got #{inspect(diagnostics)}"
    end

    test "does NOT fire when `@bond_warn_skipped_invariants false` precedes the def (per-function)" do
      source = """
      defmodule BondTest.SkippedScratch.PerFunctionSuppressed do
        use Bond
        defstruct [:value]
        @invariant subject.value >= 0

        @bond_warn_skipped_invariants false
        def label, do: "hello"
      end
      """

      diagnostics = capture_diagnostics(source)

      refute Enum.any?(diagnostics, &(&1.severity == :warning)),
             "expected no diagnostics when per-function suppression is on; got #{inspect(diagnostics)}"
    end

    test "per-function suppression scopes to one def only (subsequent def still warns)" do
      # The attribute is consumed on read at __on_definition__, so it only
      # applies to the *next* def. A later def with no override gets the
      # default behaviour (warn).
      source = """
      defmodule BondTest.SkippedScratch.ScopedToOne do
        use Bond
        defstruct [:value]
        @invariant subject.value >= 0

        @bond_warn_skipped_invariants false
        def first_helper, do: "intentional"

        def second_helper, do: "footgun"
      end
      """

      diagnostics = capture_diagnostics(source)
      warnings = Enum.filter(diagnostics, &(&1.severity == :warning))

      assert length(warnings) == 1,
             "expected exactly one warning (for second_helper/0); got #{inspect(warnings)}"

      assert String.contains?(hd(warnings).message, "second_helper/0")
    end

    test "per-function `@bond_warn_skipped_invariants true` overrides module-level suppression" do
      # Module-level says "don't warn", but the per-function override re-
      # enables the warning for this one function — useful for opting back
      # IN under a global/module-wide suppression to verify a specific
      # function's behaviour.
      source = """
      defmodule BondTest.SkippedScratch.OptedIn do
        use Bond, warn_skipped_invariants: false
        defstruct [:value]
        @invariant subject.value >= 0

        @bond_warn_skipped_invariants true
        def check_me, do: "footgun"
      end
      """

      diagnostics = capture_diagnostics(source)

      assert Enum.any?(diagnostics, fn d ->
               d.severity == :warning and String.contains?(d.message, "check_me/0")
             end),
             "expected per-function override to re-enable the warning; got #{inspect(diagnostics)}"
    end

    test "does NOT fire when invariants are `:purge`d via use Bond" do
      # :purge means contracts are removed at compile time, so warning about
      # unfired invariants is moot — the user has explicitly opted out.
      source = """
      defmodule BondTest.SkippedScratch.Purged do
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
      defmodule BondTest.SkippedScratch.DefpOnly do
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
      defmodule BondTest.SkippedScratch.MixedMatch do
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

    test "does NOT fire for a constructor whose body returns `%__MODULE__{...}`" do
      # Post-invariant check fires at runtime on the returned struct, so
      # invariants ARE checked. Bond's static heuristic detects the bare-
      # struct return shape.
      source = """
      defmodule BondTest.SkippedScratch.BareConstructor do
        use Bond
        defstruct [:value]
        @invariant subject.value >= 0

        def new(n), do: %__MODULE__{value: n}
      end
      """

      diagnostics = capture_diagnostics(source)

      refute Enum.any?(diagnostics, &(&1.severity == :warning)),
             "expected no diagnostics for bare-struct constructor; got #{inspect(diagnostics)}"
    end

    test "does NOT fire for a constructor whose body returns `{:ok, %__MODULE__{...}}`" do
      # Bond extracts the wrapped struct at the post-check site, so the runtime
      # check fires and the static heuristic detects the wrapped shape.
      source = """
      defmodule BondTest.SkippedScratch.WrappedConstructor do
        use Bond
        defstruct [:value]
        @invariant subject.value >= 0

        def try_new(n), do: {:ok, %__MODULE__{value: n}}
      end
      """

      diagnostics = capture_diagnostics(source)

      refute Enum.any?(diagnostics, &(&1.severity == :warning)),
             "expected no diagnostics for {:ok, struct} constructor; got #{inspect(diagnostics)}"
    end

    test "does NOT fire when ONE clause of a multi-clause function returns a struct" do
      # `try_new/1` shape: one clause returns {:ok, struct}, another returns
      # {:error, _}. The first clause exercises the post-check; that's enough
      # for the function as a whole to be considered "has an active check path."
      source = """
      defmodule BondTest.SkippedScratch.MixedReturn do
        use Bond
        defstruct [:value]
        @invariant subject.value >= 0

        def try_new(n) when is_integer(n) and n >= 0, do: {:ok, %__MODULE__{value: n}}
        def try_new(_), do: {:error, :invalid}
      end
      """

      diagnostics = capture_diagnostics(source)

      refute Enum.any?(diagnostics, &(&1.severity == :warning)),
             "expected no diagnostics for multi-clause with one struct-returning clause; got #{inspect(diagnostics)}"
    end

    test "FIRES for the genuine footgun: no struct in head AND no static struct return" do
      # `def update(stack, x), do: Map.put(stack, :counter, x)` — Bond can't
      # statically see that the return is a struct (it's a Map.put call), and
      # the head doesn't match the struct either. Both pre- AND post-checks
      # are skipped. THIS is the case the warning was designed to catch.
      source = """
      defmodule BondTest.SkippedScratch.GenuineFootgun do
        use Bond
        defstruct [:counter]
        @invariant subject.counter >= 0

        def update(stack, x), do: Map.put(stack, :counter, x)
      end
      """

      diagnostics = capture_diagnostics(source)

      assert Enum.any?(diagnostics, fn d ->
               d.severity == :warning and String.contains?(d.message, "update/2")
             end),
             "expected a warning for the genuine footgun (Map.put return); got #{inspect(diagnostics)}"
    end

    test "does NOT fire for a module with no @invariant declarations" do
      source = """
      defmodule BondTest.SkippedScratch.NoInvariants do
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
