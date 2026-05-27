defmodule ContractConsumer do
  @moduledoc """
  A representative downstream consumer of Bond.

  Each module below exercises a different head shape that Bond must wrap
  cleanly, with full `@spec`s so Dialyzer has a surface to analyse:

    * `Account`      — single-clause `@pre`/`@post` with a guard.
    * `Classifier`   — multi-clause dispatch with a `~>` shape-guarded `@pre`.
    * `Increment`    — default arguments (`x \\\\ default`).
    * `BoundedStack` — `@invariant` on a struct module, plus an `old/1` `@post`.
    * `Stats`        — inline `check/1`.

  The goal is breadth of *generated-code shapes*, not feature coverage; if any
  of these provoke a compiler warning (`--warnings-as-errors`) or a Dialyzer
  finding in this consumer, that's a bug to fix in Bond's code generation.
  """
end

defmodule ContractConsumer.Account do
  @moduledoc "Single-clause contract with a guard."
  use Bond

  @pre positive_amount: amount > 0
  @post non_negative_balance: result >= 0
  # Return type is `integer()` not `non_neg_integer()`: the guard guarantees
  # non-negativity at runtime, but Dialyzer can't prove it from the arithmetic,
  # and the `@post` is what actually enforces it.
  @spec withdraw(non_neg_integer(), pos_integer()) :: integer()
  def withdraw(balance, amount) when amount <= balance do
    balance - amount
  end
end

defmodule ContractConsumer.Classifier do
  @moduledoc "Multi-clause dispatch with a short-circuiting `~>` precondition."
  use Bond

  @pre non_empty_string: is_binary(value) ~> (String.length(value) > 0)
  # A relational postcondition (input shape -> output value), not a type tautology like
  # `is_atom(result)` — that would duplicate the typespec and leave Bond's generated
  # violation branch statically dead, which Dialyzer (rightly) flags.
  @post string_for_binary: is_binary(value) ~> (result == :string),
        integer_for_int: is_integer(value) ~> (result == :integer)
  @spec classify(binary() | integer()) :: :string | :integer
  def classify(value) when is_binary(value), do: :string
  def classify(value) when is_integer(value), do: :integer
end

defmodule ContractConsumer.Increment do
  @moduledoc "Default arguments combined with a contract."
  use Bond

  @pre integer_n: is_integer(n)
  @post grew_or_equal: result >= n
  @spec bump(integer(), non_neg_integer()) :: integer()
  def bump(n, by \\ 1) when by >= 0 do
    n + by
  end
end

defmodule ContractConsumer.BoundedStack do
  @moduledoc "Struct module with an `@invariant` and an `old/1` postcondition."
  use Bond

  defstruct items: [], capacity: 0

  @type t :: %__MODULE__{items: list(), capacity: non_neg_integer()}

  @invariant non_negative_capacity: subject.capacity >= 0,
             size_within_capacity: length(subject.items) <= subject.capacity

  @spec new(non_neg_integer()) :: t()
  def new(capacity) when is_integer(capacity) and capacity >= 0 do
    %__MODULE__{items: [], capacity: capacity}
  end

  @post "size grew by one": length(result.items) == old(length(stack.items)) + 1
  @spec push(t(), term()) :: t()
  def push(%__MODULE__{} = stack, item) when length(stack.items) < stack.capacity do
    %{stack | items: [item | stack.items]}
  end

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = stack) do
    length(stack.items)
  end
end

defmodule ContractConsumer.Stats do
  @moduledoc "Inline `check/1` assertion inside a function body."
  use Bond

  @spec mean([number()]) :: float()
  def mean(numbers) when is_list(numbers) and numbers != [] do
    sum = Enum.sum(numbers)
    check positive_count: length(numbers) > 0
    sum / length(numbers)
  end
end
