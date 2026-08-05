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
  """

  alias Bond.Compiler.Assertion

  @doc """
  Returns the private `{name, arity}` pairs a precondition calls, in source order.

  `private_defs` is the module's own private functions, as
  `Module.definitions_in(module, :defp)` reports them at `@before_compile`.

  Local-call resolution makes a match definitive rather than heuristic: if
  `{name, arity}` names a private function of this module, Elixir resolves the call to it
  over any import, so nothing else could be meant.
  """
  @spec private_calls(Assertion.t(), MapSet.t()) :: [{atom(), non_neg_integer()}]
  def private_calls(%Assertion{expression: expression}, private_defs) do
    {_ast, found} =
      Macro.prewalk(expression, [], fn
        # A local call: an atom name with a list of arguments. A *variable* carries an
        # atom or nil context in that position instead of a list, and a remote call carries
        # a `{:., _, [mod, fun]}` tuple as its name — neither can match here.
        {name, _meta, args} = node, acc when is_atom(name) and is_list(args) ->
          pair = {name, length(args)}
          if MapSet.member?(private_defs, pair), do: {node, [pair | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    found |> Enum.reverse() |> Enum.uniq()
  end

  @doc """
  The warning text for one function whose preconditions call private predicates.
  """
  @spec warning_message(module(), atom(), non_neg_integer(), [{atom(), non_neg_integer()}]) ::
          String.t()
  def warning_message(module, fun, arity, calls) do
    rendered = Enum.map_join(calls, ", ", fn {name, a} -> "`#{name}/#{a}`" end)
    plural = if length(calls) == 1, do: "a private function", else: "private functions"

    "the precondition of public function `#{fun}/#{arity}` in `#{inspect(module)}` calls " <>
      "#{plural} (#{rendered}). A precondition is an obligation on the caller, so a caller " <>
      "that cannot call #{rendered} cannot check it before calling — and Bond renders the " <>
      "assertion into the generated docs, where #{rendered} does not appear. Make the " <>
      "predicate public, or inline the condition. (Meyer's Precondition Availability rule, " <>
      "OOSC §11.7.) Postconditions are exempt. Suppress with " <>
      "`@bond_warn_unavailable_preconditions false` (per function), " <>
      "`use Bond, warn_unavailable_preconditions: false` (per module), or " <>
      "`config :bond, warn_unavailable_preconditions: false` (globally)."
  end
end
