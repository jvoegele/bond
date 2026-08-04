## Fixtures for Bond.StacktraceTest (#75).
##
## Each module records the source line of its first `def` clause with
## `__ENV__.line`, so the tests can assert on an exact line without hard-coding a
## number that would rot the moment this file is edited. A FunctionClauseError
## reports the line of the function's first clause, which is what these expose.

defmodule BondTest.Stacktrace.MultiClause do
  @moduledoc false
  use Bond

  @pre sane: is_list(items) or is_map(items)
  @first_clause_line __ENV__.line + 1
  def count(%{} = items), do: map_size(items)
  def count(items) when is_list(items), do: length(items)

  def first_clause_line, do: @first_clause_line
end

defmodule BondTest.Stacktrace.SingleClause do
  @moduledoc false
  use Bond

  @pre sane: is_list(items)
  @first_clause_line __ENV__.line + 1
  def count(items) when is_list(items), do: length(items)

  def first_clause_line, do: @first_clause_line
end

defmodule BondTest.Stacktrace.Guarded do
  @moduledoc false
  use Bond

  @pre positive: n > 0
  @first_clause_line __ENV__.line + 1
  def classify(n) when is_integer(n) and n > 10, do: :big
  def classify(n) when is_integer(n), do: :small

  def first_clause_line, do: @first_clause_line
end

defmodule BondTest.Stacktrace.WithInvariant do
  @moduledoc false
  use Bond

  defstruct [:v]

  @invariant positive: subject.v > 0

  @first_clause_line __ENV__.line + 1
  def bump(%__MODULE__{} = s), do: %{s | v: s.v + 1}

  def first_clause_line, do: @first_clause_line
end

defmodule BondTest.Stacktrace.PreFails do
  @moduledoc false
  # A call that MATCHES a clause but violates the precondition, so the
  # Bond.PreconditionError path can be checked for position too. (A call that
  # matches no clause raises FunctionClauseError before any contract runs.)
  use Bond

  @pre positive: n > 0
  @first_clause_line __ENV__.line + 1
  def double(n) when is_integer(n), do: n * 2

  def first_clause_line, do: @first_clause_line
end

defmodule BondTest.Stacktrace.Uncontracted do
  @moduledoc false
  # Same shape, no `use Bond` — the baseline the contracted modules must match.
  @first_clause_line __ENV__.line + 1
  def count(%{} = items), do: map_size(items)
  def count(items) when is_list(items), do: length(items)

  def first_clause_line, do: @first_clause_line
end
