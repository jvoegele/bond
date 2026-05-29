defmodule BondTest.QualifiedSyntax do
  @moduledoc """
  Fixture for the `use Bond, at_annotations: false` escape hatch: contracts written as
  fully-qualified `Bond.pre` / `Bond.post` / `Bond.invariant` calls, which must behave
  identically to the `@pre` / `@post` / `@invariant` forms.

  `warn_skipped_invariants: false` because several functions here take no struct parameter
  (the module-scoped invariant is silently skipped for them) — that's incidental to what this
  fixture exercises, not the behaviour under test.
  """

  use Bond, at_annotations: false, warn_skipped_invariants: false

  defstruct [:items, :capacity]

  Bond.invariant(
    non_negative_size: length(subject.items) >= 0,
    within_capacity: length(subject.items) <= subject.capacity
  )

  # Bare precondition + bare postcondition (the `result` binding is injected by the compiler
  # regardless of which front-end registered the contract).
  Bond.pre(is_integer(n) and n >= 0)
  Bond.post(result == n * 2)
  def double(n), do: n * 2

  # A postcondition that can actually fail, to prove `Bond.post` is enforced rather than
  # silently dropped.
  Bond.post(result > 0)
  def passthrough(n), do: n

  # Keyword-list (labelled) precondition with atom-key labels.
  Bond.pre(positive: x > 0, bounded: x < 100)
  def bounded(x), do: x

  # Keyword-list label with a quoted-string key — the migration path for the old positional
  # string-label form (`Bond.pre z > 0, "z must be positive"`, removed in 1.0).
  Bond.pre("z must be positive": z > 0)
  def string_labelled(z), do: z

  def new(capacity) when is_integer(capacity) and capacity >= 0 do
    %__MODULE__{items: [], capacity: capacity}
  end

  # Struct-taking function: both the pre- and post-invariant fire here.
  def push(%__MODULE__{} = s, item) do
    %{s | items: [item | s.items]}
  end

  # Deliberately ignores capacity so the post-invariant `within_capacity` can be violated,
  # proving `Bond.invariant` is enforced.
  def overfill(%__MODULE__{} = s, item) do
    %{s | items: [item | s.items]}
  end
end
