## Fixtures for Bond.SkippedInvariantsWarningTest.
##
## Each module exercises one configuration of the `warn_skipped_invariants`
## warning at a different scope: module-level suppression via `use Bond`,
## per-function suppression via `@bond_warn_skipped_invariants`, defp
## exemption, mixed-clause matching, and `:purge` suppression.
##
## Modules that would otherwise trigger warnings during the normal test run
## suppress at the appropriate scope so the suite compiles silently. The test
## file uses `Code.compile_string/1` to compile equivalent unsuppressed
## sources and inspect the diagnostics.

defmodule BondTest.SkippedInvariants.AllSuppressed do
  @moduledoc false

  # Suppressed module-wide via `use Bond`. Has @invariant + public def with no
  # struct match. Existence here is the negative test: the suite must compile
  # without warnings.
  use Bond, warn_skipped_invariants: false

  defstruct [:value]

  @invariant subject.value >= 0

  # Public function that doesn't pattern-match the struct — silently skips
  # invariants. The module-wide suppression keeps the compile clean.
  def label, do: "module label"
end

defmodule BondTest.SkippedInvariants.PerFunctionSuppressed do
  @moduledoc false

  # Per-function suppression via `@bond_warn_skipped_invariants false` on
  # `class_name/0` only. `push/2` still gets the safety net — if its head
  # were later changed to no longer match the struct, the warning would
  # fire as designed.
  use Bond

  defstruct [:items]

  @invariant length(subject.items) >= 0

  @bond_warn_skipped_invariants false
  def class_name, do: "stack"

  def push(%__MODULE__{} = s, x), do: %{s | items: [x | s.items]}
end

defmodule BondTest.SkippedInvariants.SilentDefp do
  @moduledoc false

  # No suppression needed: defp is exempt from invariants by design, so
  # the warning shouldn't fire.
  use Bond

  defstruct [:value]

  @invariant subject.value >= 0

  def matched(%__MODULE__{} = s), do: s.value

  # defp — exempt; no warning expected.
  defp _helper(x), do: x
end

defmodule BondTest.SkippedInvariants.MixedClauses do
  @moduledoc false

  # Multi-clause public function where one clause matches the struct; the
  # other doesn't. Mixed match → no warning (a clause matches; invariants
  # fire at least somewhere).
  use Bond

  defstruct [:value]

  @invariant subject.value >= 0

  def coerce(%__MODULE__{} = s), do: s
  def coerce(v) when is_integer(v), do: %__MODULE__{value: v}
end
