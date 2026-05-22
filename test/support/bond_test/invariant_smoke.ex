defmodule BondTest.InvariantSmoke do
  @moduledoc """
  Compile-time smoke test for the `@invariant` macro and end-to-end emission.

  Exercises the three canonical syntactic forms (single labeled, multi labeled, alternative
  binding name) plus a public function whose head pattern-matches the struct, so the lifted
  invariants defp and the pre/post call sites get emitted. Failing-case behaviour is
  exercised in `test/bond/runtime/` and `test/bond/compiler/`.
  """

  use Bond

  defstruct [:items, :capacity]

  @invariant(stack, non_negative_capacity: stack.capacity >= 0)

  @invariant(stack,
    size_within_capacity: length(stack.items) <= stack.capacity,
    non_negative_size: length(stack.items) >= 0
  )

  def new(capacity) when is_integer(capacity) and capacity > 0 do
    %__MODULE__{items: [], capacity: capacity}
  end

  def push(%__MODULE__{} = stack, item) do
    %{stack | items: [item | stack.items]}
  end
end
