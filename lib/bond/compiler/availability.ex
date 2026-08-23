defmodule Bond.Compiler.Availability do
  @moduledoc internal: true
  @moduledoc """
  Detects preconditions a caller cannot evaluate (#92).

  A precondition is an obligation on the *caller*. If it is stated in terms the caller
  cannot reach, the obligation cannot be discharged and what looks like an agreement is a
  one-sided demand. Meyer makes this a language rule rather than advice
  (*Object-Oriented Software Construction*, 2nd edition, §11.7, p. 358):

  > **Precondition Availability rule**
  >
  > Every feature appearing in the precondition of a routine must be available to every
  > client to which the routine is available.

  Elixir has one visibility boundary — `def` versus `defp` — so the rule reduces to: a
  **public** function's precondition should not call a **private** function of the same
  module. Bond compiles that happily, and the generated docs then publish the caller's
  obligation in terms of a function excluded from those same docs.

  Only preconditions are checked. Meyer is explicit that postconditions are exempt:
  "There is no such rule for postconditions. It is not an error for some clauses of a
  postcondition clause to refer to secret features." A postcondition is the function's
  promise, not the caller's obligation, so it may say things the caller cannot verify.
  Invariants and `check/1` are likewise not caller obligations.

  Unlike the guard-restating precondition described in the FAQ — which needs to know what
  a guard admits, and so stays advice — this one is statically decidable: Bond knows which
  functions are private.

  ## `@doc false` (#110)

  `defp` is the strict reading of Meyer's rule, since Elixir's only visibility boundary is
  `def` versus `defp`. But the justification above turns on *documentation*: the generated
  docs publish the caller's obligation in terms the docs do not explain. A **public**
  function carrying `@doc false` defeats that in exactly the same way — it is callable, so
  Meyer's rule is satisfied, yet it does not appear in the docs a caller reads, so the
  obligation is undiscoverable.

  Both are reported, with wording that distinguishes them, because the fix differs:
  a private predicate is made public, a hidden one has its `@doc false` removed.

  One exception keeps the second check honest. When the *contracted* function is itself
  `@doc false`, its precondition is not published either, so nothing is defeated and the
  `:hidden` reason is not reported. `:private` still is: Meyer's rule is about
  callability, which does not depend on what is published.
  """

  alias Bond.Compiler.Assertion

  @typedoc "Why a called function is unreachable to the caller."
  @type reason :: :private | :hidden

  @doc """
  Returns the unreachable `{{name, arity}, reason}` pairs a precondition calls, in source
  order. `reason` is `:private` or `:hidden`.

  `private_defs` is the module's own private functions, as
  `Module.definitions_in(module, :defp)` reports them at `@before_compile`. `hidden_defs`
  is its **public** functions carrying `@doc false`.

  Local-call resolution makes a match definitive rather than heuristic: if
  `{name, arity}` names a function of this module, Elixir resolves the call to it over any
  import, so nothing else could be meant.
  """
  @spec unavailable_calls(Assertion.t(), MapSet.t(), MapSet.t()) ::
          [{{atom(), non_neg_integer()}, reason()}]
  def unavailable_calls(%Assertion{expression: expression}, private_defs, hidden_defs) do
    {_ast, found} =
      Macro.prewalk(expression, [], fn
        # A local call: an atom name with a list of arguments. A *variable* carries an
        # atom or nil context in that position instead of a list, and a remote call carries
        # a `{:., _, [mod, fun]}` tuple as its name — neither can match here.
        {name, _meta, args} = node, acc when is_atom(name) and is_list(args) ->
          pair = {name, length(args)}

          cond do
            MapSet.member?(private_defs, pair) -> {node, [{pair, :private} | acc]}
            MapSet.member?(hidden_defs, pair) -> {node, [{pair, :hidden} | acc]}
            true -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    found |> Enum.reverse() |> Enum.uniq()
  end

  @doc """
  The warning text for one function whose preconditions call predicates its callers cannot
  reach. `calls` is what `unavailable_calls/3` returned.
  """
  @spec warning_message(module(), atom(), non_neg_integer(), [
          {{atom(), non_neg_integer()}, reason()}
        ]) :: String.t()
  def warning_message(module, fun, arity, calls) do
    {private, hidden} = Enum.split_with(calls, fn {_pair, reason} -> reason == :private end)

    clauses =
      [private_clause(private), hidden_clause(hidden)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    "the precondition of public function `#{fun}/#{arity}` in `#{inspect(module)}` is " <>
      "stated in terms its callers cannot reach. #{clauses} " <>
      "(Meyer's Precondition Availability rule, OOSC §11.7.) Postconditions are exempt. " <>
      "Suppress with `@bond_warn_unavailable_preconditions false` (per function), " <>
      "`use Bond, warn_unavailable_preconditions: false` (per module), or " <>
      "`config :bond, warn_unavailable_preconditions: false` (globally)."
  end

  defp private_clause([]), do: nil

  defp private_clause(calls) do
    rendered = render(calls)
    noun = if length(calls) == 1, do: "a private function", else: "private functions"

    "It calls #{noun} (#{rendered}): a precondition is an obligation on the caller, so a " <>
      "caller that cannot call #{rendered} cannot check it before calling — and Bond renders " <>
      "the assertion into the generated docs, where #{rendered} does not appear. Make the " <>
      "predicate public, or inline the condition."
  end

  defp hidden_clause([]), do: nil

  defp hidden_clause(calls) do
    rendered = render(calls)
    {noun, verb} = if length(calls) == 1, do: {"a function", "is"}, else: {"functions", "are"}

    "It calls #{noun} (#{rendered}) that #{verb} public but hidden from the generated docs " <>
      "by `@doc false`. Bond renders the assertion into those docs, so a caller reading them " <>
      "cannot discover what they are required to satisfy. Remove the `@doc false`, or inline " <>
      "the condition."
  end

  defp render(calls), do: Enum.map_join(calls, ", ", fn {{name, a}, _} -> "`#{name}/#{a}`" end)
end
