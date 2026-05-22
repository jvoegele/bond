defmodule BondTest.InvariantSmoke do
  @moduledoc """
  Compile-time smoke test for the `@invariant` macro: if this module compiles, the macro
  parses the canonical syntax forms correctly. Emission isn't wired up yet (Mikado steps 7
  and 8 add it), so there is no runtime behaviour to assert against in 0.13.0-dev.
  """

  use Bond

  defstruct [:items, :capacity]

  @invariant stack, non_negative_capacity: stack.capacity >= 0

  @invariant stack,
             size_within_capacity: length(stack.items) <= stack.capacity,
             non_negative_size: length(stack.items) >= 0

  @invariant other_name, foo_bar: other_name.capacity == other_name.capacity

  def new(capacity) when is_integer(capacity) and capacity > 0 do
    %__MODULE__{items: [], capacity: capacity}
  end
end
