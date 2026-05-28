## Fixtures for Bond.UnmatchedInvariantSubjectWarningTest.
##
## Each module exercises one configuration of the warning: on/off via use Bond
## option, mixed-clause cases, defp exemption, and :purge suppression. Modules
## here that SHOULD warn use `warn_unmatched_invariant_subject: false` so they
## compile silently during the normal test run; the test file uses
## `Code.compile_string/1` to compile equivalent unsuppressed sources and
## inspect the diagnostics.

defmodule BondTest.UnmatchedSubject.AllSuppressed do
  @moduledoc false

  # Suppressed via use Bond. Has @invariant + public def with no struct match.
  # Existence here is the negative test: the suite must compile without warnings.
  use Bond, warn_unmatched_invariant_subject: false

  defstruct [:value]

  @invariant subject.value >= 0

  # Public function that doesn't pattern-match the struct — silently skips
  # invariants. The suppression option keeps the compile clean.
  def label, do: "module label"
end

defmodule BondTest.UnmatchedSubject.SilentDefp do
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

defmodule BondTest.UnmatchedSubject.MixedClauses do
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
