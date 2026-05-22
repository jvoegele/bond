defmodule BondTest.SubjectInvariantSmoke do
  @moduledoc """
  Fixture exercising the 0.16.0 `@invariant <expr_or_kw>` syntax — no binding-name
  argument, expressions reference the implicit `subject` binding.

  Covers:

    - `push/2` — `%__MODULE__{} = stack` pattern; both pre- and post-invariant fire.
    - `reverse/1` — bare param with `is_struct(_, __MODULE__)` guard; exercises the
      guard-detection path.
    - `concat/2` — two struct parameters; both pre-invariants fire, with `subject`
      rebinding to each in turn.
    - `mismatched_pair/2` — second struct parameter only; non-zero-position detection.
    - `broken_push/2` — intentionally produces an invalid struct so tests can drive
      a post-invariant violation.
    - `head/1` — destructure-only head (`%__MODULE__{items: [first | _]}`, no `= name`).
      Exercises S4's override-clause rewrite that captures the struct under
      `__bond_subject_0__` so the pre-invariant can fire.
    - `rotate/1` — destructure-only head returning a struct. Exercises both the
      pre-invariant (via the captured binding) and the post-invariant on the
      returned struct.
  """

  use Bond

  defstruct [:items, :capacity]

  @invariant non_negative_capacity: subject.capacity >= 0,
             size_within_capacity: length(subject.items) <= subject.capacity,
             non_negative_size: length(subject.items) >= 0

  def new(capacity) when is_integer(capacity) and capacity >= 0 do
    %__MODULE__{items: [], capacity: capacity}
  end

  def push(%__MODULE__{} = stack, item) do
    if length(stack.items) >= stack.capacity do
      {:error, :full}
    else
      %{stack | items: [item | stack.items]}
    end
  end

  def reverse(stack) when is_struct(stack, __MODULE__) do
    %{stack | items: Enum.reverse(stack.items)}
  end

  def concat(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{items: a.items ++ b.items, capacity: a.capacity + b.capacity}
  end

  def mismatched_pair(label, %__MODULE__{} = stack) when is_atom(label) do
    {label, stack}
  end

  def broken_push(%__MODULE__{} = stack, item) do
    %{stack | items: [item, item, item, item | stack.items]}
  end

  def head(%__MODULE__{items: [first | _]}), do: first

  def rotate(%__MODULE__{items: [first | rest], capacity: cap}) do
    %__MODULE__{items: rest ++ [first], capacity: cap}
  end
end
