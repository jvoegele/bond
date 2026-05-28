defmodule BondTest.SynthesizedModuledocInvariant do
  # No @moduledoc — verifies that 0.17.1's moduledoc-invariants augmentation
  # SYNTHESISES a moduledoc containing the Invariants section when the user
  # didn't write one but the module has @invariant declarations.
  use Bond

  defstruct [:n]

  @invariant non_negative: subject.n >= 0

  # Constructor: takes the inputs, not the struct itself.
  @bond_warn_skipped_invariants false
  def new(n), do: %__MODULE__{n: n}
end
