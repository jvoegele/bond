defmodule BondTest.InvariantSmoke do
  @moduledoc """
  Fixture exercising `@invariant` end-to-end.

  Declares invariants on a bounded-stack struct and provides functions covering each
  emission path:

    - `push/2` — takes the struct, returns the struct. Both pre- and post-invariant fire.
    - `try_new/1` — returns `{:ok, %__MODULE__{}}`. The post-invariant case extraction
      matches the wrapped-return shape.
    - `broken_push/2` — intentionally produces an invalid struct so tests can drive a
      post-invariant violation.
    - `bypass_invariants_via_defp/2` — delegates to a private function that, by design,
      doesn't have invariants applied (the Eiffel-style exemption for `defp`).
    - `capacity/1` — returns a non-struct (an integer). Exercises the post-case
      extraction's fall-through branch (no invariant check, no error).
  """

  use Bond

  defstruct [:items, :capacity]

  @invariant non_negative_capacity: subject.capacity >= 0,
             size_within_capacity: length(subject.items) <= subject.capacity,
             non_negative_size: length(subject.items) >= 0

  def new(capacity) when is_integer(capacity) and capacity >= 0 do
    %__MODULE__{items: [], capacity: capacity}
  end

  def try_new(capacity) when is_integer(capacity) and capacity >= 0 do
    {:ok, %__MODULE__{items: [], capacity: capacity}}
  end

  def try_new(_), do: {:error, :invalid_capacity}

  def push(%__MODULE__{} = stack, item) do
    if length(stack.items) >= stack.capacity do
      {:error, :full}
    else
      %{stack | items: [item | stack.items]}
    end
  end

  # Intentionally produces an invariant-violating struct: items exceeds capacity.
  def broken_push(%__MODULE__{} = stack, item) do
    %{stack | items: [item, item, item, item | stack.items]}
  end

  # Exit-order probe: on return BOTH the postcondition and the post-invariant
  # are violated. The postcondition `must_shrink` is false (we add items, so the
  # result is larger), and the result overflows `capacity`, violating the
  # `size_within_capacity` invariant. Per ECMA-367 §8.23.26 the invariant (step
  # 12) is evaluated before the postcondition (step 13), so the invariant error
  # must surface. The exit-order test asserts that to lock in the ordering.
  @post must_shrink: length(result.items) < length(stack.items)
  def overflowing_post(%__MODULE__{} = stack, item) do
    %{stack | items: [item, item, item, item | stack.items]}
  end

  def bypass_invariants_via_defp(%__MODULE__{} = stack, item) do
    do_overflow(stack, item)
  end

  defp do_overflow(stack, item) do
    %{stack | items: List.duplicate(item, stack.capacity + 10)}
  end

  def capacity(%__MODULE__{} = stack), do: stack.capacity
end
