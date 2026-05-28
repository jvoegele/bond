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

defmodule ContractConsumer.TypedGuard do
  @moduledoc """
  Regression fixture for downstream-Dialyzer "Pattern: `false`, Type: `true`"
  warnings caused by tautological assertions.

  Each function below has an `@pre`/`@post`/`@invariant` whose expression
  duplicates a type-narrowing guard already implied by the `@spec`. Without
  Bond's parameter-laundering through `Bond.Predicates.__opaque__/1`,
  Dialyzer narrowed the lifted defp's parameter types from the wrapper's
  `@spec`, then proved branches of the user expression's `if`/`and`/`or`/
  `case` expansion dead — emitting a `pattern_match` warning at the lifted
  defp's `generated: true` location (line 1 of the using module).

  The smoke tests are downstream Dialyzer running clean against this module
  and the runtime behaviour still firing on actual violations.
  """
  use Bond

  @pre binary_value: is_binary(value)
  @spec stringify(binary()) :: binary()
  def stringify(value) do
    value <> "!"
  end

  @pre atom_key: is_atom(key)
  @spec atom_label(atom()) :: binary()
  def atom_label(key) do
    Atom.to_string(key)
  end

  @post non_empty_result: is_binary(result) and result != ""
  @spec key_to_string(atom()) :: binary()
  def key_to_string(key) do
    Atom.to_string(key)
  end

  # `~>` antecedent is statically `true` under the spec: without laundering, the
  # `else: true` branch of `~>`'s `if` expansion is unreachable.
  @pre matches_ok_shape: is_tuple(pair) ~> (tuple_size(pair) >= 1)
  @spec normalize(tuple()) :: :ok
  def normalize(pair) when is_tuple(pair), do: :ok

  # `<~` discriminator is statically a tuple matching the pattern: without laundering,
  # the `_unmatched -> false` clause is `pattern_match_cov`.
  @post returns_ok: {:ok, _} <~ result
  @spec wrap(integer()) :: {:ok, integer()}
  def wrap(n) do
    {:ok, n}
  end
end

defmodule ContractConsumer.TypedInvariant do
  @moduledoc """
  Regression fixture for tautological `@invariant` expressions whose `@type`
  already implies the invariant's truthiness. The lifted invariant defp's
  parameter is laundered at the call site (see
  `Bond.Compiler.Invariants.all_pre_invariant_stmts/5`) so user expressions
  containing `and`/`or`/etc. don't get one branch flagged as dead by Dialyzer.
  """
  use Bond

  defstruct count: 0, label: ""

  @type t :: %__MODULE__{count: non_neg_integer(), label: binary()}

  # `is_binary(subject.label)` is statically true given the `@type`, and
  # `subject.count >= 0` is statically true given `non_neg_integer()`. The
  # `and/2` expansion contains a `case` whose `false` clause Dialyzer would
  # otherwise prove unreachable.
  @invariant well_formed: is_binary(subject.label) and subject.count >= 0

  @spec new(binary(), non_neg_integer()) :: t()
  def new(label, count) do
    %__MODULE__{label: label, count: count}
  end

  @spec increment(t()) :: t()
  def increment(%__MODULE__{} = state) do
    %{state | count: state.count + 1}
  end
end
