defmodule BondTest.PurgedInvariantsFixture do
  @moduledoc """
  User-authored moduledoc that should be preserved verbatim — the per-module
  `invariants: :purge` opt should suppress the auto-generated Invariants
  section the same way it suppresses per-function contract docs.
  """

  use Bond, invariants: :purge

  defstruct [:n]

  @invariant non_negative: subject.n >= 0

  def new(n), do: %__MODULE__{n: n}
end
