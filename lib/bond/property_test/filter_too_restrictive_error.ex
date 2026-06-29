defmodule Bond.PropertyTest.FilterTooRestrictiveError do
  @moduledoc """
  Raised by `Bond.PropertyTest.probe_contract/2` when a function's precondition is so restrictive
  that StreamData discards too many consecutive generated inputs before finding enough that satisfy
  `@pre`.

  `probe_contract/2` uses the precondition as a *filter*: generated inputs that violate `@pre` are
  discarded rather than failing the property. When almost every generated value is discarded,
  StreamData gives up with its generic `StreamData.FilterTooNarrowError`. Bond rescues that and
  re-raises this error instead, naming the function whose precondition did the filtering and
  pointing at the usual fixes — so the message is actionable rather than a bare "too many filtered".

  The fix is almost always to make the base generators produce valid inputs more often: narrow them
  to the precondition's domain, or use `StreamData.bind/2` to build inputs that satisfy a
  *relational* precondition (e.g. `amount <= account.balance`), which boundary injection can't probe
  for you.
  """

  defexception [:module, :function, :arity, :last_generated_value]

  @type t :: %__MODULE__{
          module: module(),
          function: atom(),
          arity: non_neg_integer(),
          last_generated_value: {:value, term()} | :none
        }

  @impl true
  def message(%__MODULE__{module: mod, function: fun, arity: arity} = error) do
    """
    probe_contract could not generate enough inputs satisfying the precondition of \
    #{inspect(mod)}.#{fun}/#{arity}: StreamData discarded too many consecutive generated values \
    that failed @pre.

    Narrow your base generators so they produce valid inputs more often, or use StreamData.bind/2 \
    to build inputs that satisfy a relational precondition (e.g. `amount <= account.balance`), \
    which boundary injection can't probe for you.\
    #{last_generated_hint(error.last_generated_value)}
    """
  end

  defp last_generated_hint({:value, value}), do: "\n\nLast generated value: #{inspect(value)}"
  defp last_generated_hint(_none), do: ""
end
