defmodule BondTest.HiddenModuledocFixture do
  @moduledoc false

  use Bond

  defstruct [:n]

  @invariant non_negative: subject.n >= 0

  # Constructor: takes the inputs, not the struct itself.
  @bond_warn_skipped_invariants false
  def new(n), do: %__MODULE__{n: n}
end
