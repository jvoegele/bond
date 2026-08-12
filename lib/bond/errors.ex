defmodule Bond.AssertionError do
  @moduledoc internal: true

  defmacro __using__(_opts) do
    quote generated: true do
      defexception [
        :label,
        :kind,
        :expression,
        :file,
        :line,
        :module,
        :function,
        :binding,
        :source_behaviour,
        :source_contract,
        :source_protocol,
        :impl,
        :quantifier,
        # Set only on `Bond.AssertionEvaluationError`: the exception the assertion
        # expression raised, and its stacktrace. `nil` on every violation type.
        :exception,
        :original_stacktrace
      ]

      @typedoc """
      The `#{inspect(__MODULE__)}` exception type.

      `:kind` is the assertion kind (`:precondition`, `:postcondition`, `:invariant`,
      `:state_invariant`, `:transition_invariant`, or `:check`). For `Bond.InvariantError` it
      distinguishes a struct `@invariant` from a `Bond.Server` `@state_invariant` /
      `@transition_invariant`; for the others it is redundant with the struct type.

      `:source_behaviour` is the behaviour module an inherited contract came from (see
      `Bond.Behaviour`), or `nil` for a contract declared directly on the function.

      `:source_contract` is the `{module, name}` of an applied named contract the failing
      assertion came from (see `defcontract`/`@apply_contract`), or `nil` otherwise.

      `:source_protocol` is the protocol module a contract was declared on (see `Bond.Protocol`),
      or `nil`; when set, `:impl` is the implementation module the failing call resolved to (or
      `nil` if none could be resolved).

      `:quantifier` carries element-level failure detail when the assertion used `forall`/`exists`
      (see `Bond.Predicates`), or `nil` otherwise.
      """
      @type t :: %__MODULE__{
              label: Bond.assertion_label(),
              # One of :precondition | :postcondition | :invariant | :state_invariant |
              # :transition_invariant | :check (see `t:Bond.assertion_kind/0`, hidden).
              kind: atom(),
              expression: Bond.assertion_expression(),
              file: Path.t(),
              line: integer(),
              module: module(),
              function: {String.t(), non_neg_integer()},
              binding: keyword(),
              source_behaviour: module() | nil,
              source_contract: {module(), atom()} | nil,
              source_protocol: module() | nil,
              impl: module() | nil,
              quantifier: map() | nil,
              exception: Exception.t() | nil,
              original_stacktrace: Exception.stacktrace() | nil
            }

      @impl Exception
      def exception(%{label: _label, binding: _binding} = assertion_failure_info) do
        struct(__MODULE__, assertion_failure_info)
      end

      def exception(opts) when is_list(opts) do
        assertion = Keyword.fetch!(opts, :assertion)
        assertion_env = assertion.definition_env
        function_env = Keyword.fetch!(opts, :env)
        binding = Keyword.fetch!(opts, :binding)

        %__MODULE__{
          label: assertion.label,
          kind: assertion.kind,
          expression: assertion.code,
          file: assertion_env.file,
          line: assertion_env.line,
          module: assertion_env.module,
          function: function_env.function,
          binding: binding,
          source_behaviour: Map.get(assertion, :source_behaviour),
          source_contract: Map.get(assertion, :source_contract)
        }
      end
    end
  end

  @doc """
  Returns a parenthetical attribution naming where an inherited contract came from, for the
  precondition/postcondition messages, or `""` for a contract declared directly on the function.

  A behaviour-inherited contract (see `Bond.Behaviour`) reads `" (inherited from Ledger)"`; a
  protocol contract (see `Bond.Protocol`) reads `" (from protocol Sized, impl Sized.List)"`,
  dropping the `impl` clause when it could not be resolved. An applied named contract (see
  `defcontract`/`@apply_contract`) reads `" (from contract Money.withdrawal)"`, abbreviating to
  `" (from contract :withdrawal)"` when the contract was defined in the failing call's own module.
  """
  def attribution(%{source_protocol: protocol} = error) when not is_nil(protocol) do
    impl_part = if error.impl, do: ", impl #{inspect(error.impl)}", else: ""
    " (from protocol #{inspect(protocol)}#{impl_part})"
  end

  def attribution(%{source_behaviour: behaviour}) when not is_nil(behaviour) do
    " (inherited from #{inspect(behaviour)})"
  end

  def attribution(%{source_contract: {contract_module, name}} = error) do
    if contract_module == error.module do
      " (from contract #{inspect(name)})"
    else
      " (from contract #{inspect(contract_module)}.#{name})"
    end
  end

  def attribution(_error), do: ""

  def message(error, headline) do
    location =
      case {error.file, error.line} do
        {nil, _} -> nil
        {file, nil} -> file
        {file, line} -> "#{file}:#{line}"
      end

    location_line = if location, do: "|   at: #{location}\n", else: ""
    counterexample_line = format_counterexample(Map.get(error, :quantifier))

    """
    #{headline}
    #{location_line}|   label: #{inspect(error.label)}
    |   assertion: #{error.expression}
    #{counterexample_line}|   binding: #{format_binding(error.binding)}
    """
  end

  # Renders the element-level `counterexample:` line for a quantified assertion (`forall`/
  # `exists`), or `""` for an ordinary assertion. `forall` names the offending element and its
  # zero-based index; `exists` reports that no element satisfied the predicate, with the count.
  # The `:pattern`-kind variants report a *generator-pattern* mismatch (issue #55) rather than an
  # unsatisfied predicate.
  defp format_counterexample(nil), do: ""

  defp format_counterexample(%{
         quantifier: :forall,
         kind: :predicate,
         element: element,
         index: index,
         predicate: predicate
       }) do
    "|   counterexample: element at index #{index} (#{inspect(element)}) does not satisfy " <>
      "`#{predicate}`\n"
  end

  defp format_counterexample(%{
         quantifier: :forall,
         kind: :pattern,
         element: element,
         index: index,
         pattern: pattern
       }) do
    "|   counterexample: element at index #{index} (#{inspect(element)}) does not match pattern " <>
      "`#{pattern}`\n"
  end

  defp format_counterexample(%{
         quantifier: :exists,
         kind: :predicate,
         predicate: predicate,
         count: count,
         enum_code: enum_code
       }) do
    "|   counterexample: no element of `#{enum_code}` satisfies `#{predicate}` " <>
      "(#{count} #{pluralize(count, "element")})\n"
  end

  defp format_counterexample(%{
         quantifier: :exists,
         kind: :pattern,
         pattern: pattern,
         count: count,
         enum_code: enum_code
       }) do
    "|   counterexample: no element of `#{enum_code}` matches pattern `#{pattern}` " <>
      "(#{count} #{pluralize(count, "element")})\n"
  end

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

  # The binding can include arbitrary user values — large structs, deep maps, big lists. Use
  # `inspect/2` with conservative `limit`/`printable_limit` defaults so the failure message
  # stays readable for both small bindings (`[x: -1]`) and giant ones.
  defp format_binding(binding) do
    inspect(binding, pretty: true, limit: 20, printable_limit: 200, width: 80)
  end
end

defmodule Bond.PreconditionError do
  @moduledoc """
  Exception raised when a function precondition fails.
  """

  use Bond.AssertionError

  @impl Exception
  def message(%{module: module, function: {function, arity}} = error) do
    Bond.AssertionError.message(
      error,
      "precondition#{Bond.AssertionError.attribution(error)} failed " <>
        "for call to #{inspect(module)}.#{function}/#{arity}"
    )
  end
end

defmodule Bond.PostconditionError do
  @moduledoc """
  Exception raised when a function postcondition fails.
  """

  use Bond.AssertionError

  @impl Exception
  def message(%{module: module, function: {function, arity}} = error) do
    Bond.AssertionError.message(
      error,
      "postcondition#{Bond.AssertionError.attribution(error)} failed " <>
        "in #{inspect(module)}.#{function}/#{arity}"
    )
  end
end

defmodule Bond.CheckError do
  @moduledoc """
  Exception raised when a `Bond.check/1` assertion fails.
  """

  use Bond.AssertionError

  @impl Exception
  def message(%{module: module, function: {function, arity}} = error) do
    Bond.AssertionError.message(
      error,
      "check failed in #{inspect(module)}.#{function}/#{arity}"
    )
  end
end

defmodule Bond.InvariantError do
  @moduledoc """
  Exception raised when an invariant is violated.

  Covers all three invariant flavours, distinguished by the `:kind` field:

    * a struct `@invariant` (`:kind` `:invariant`) — checked when a public function in the struct's
      defining module receives or returns a value of the struct (`:function` is that function);
    * a `Bond.Server` `@state_invariant` (`:kind` `:state_invariant`) — checked after every
      state-transition callback returns a new state (`:function` is that callback);
    * a `Bond.Server` `@transition_invariant` (`:kind` `:transition_invariant`) — checked across
      every transition callback, relating `old_state` to `new_state` (`:function` is that callback).
  """

  use Bond.AssertionError

  @impl Exception
  def message(%{kind: kind, module: module, function: {function, arity}} = error) do
    Bond.AssertionError.message(error, headline(kind, "#{inspect(module)}.#{function}/#{arity}"))
  end

  defp headline(:state_invariant, mfa), do: "state invariant violated after #{mfa}"
  defp headline(:transition_invariant, mfa), do: "transition invariant violated across #{mfa}"
  defp headline(_struct_invariant, mfa), do: "invariant violated around #{mfa}"
end

defmodule Bond.AssertionEvaluationError do
  @moduledoc """
  Exception raised when an assertion expression itself raises, rather than
  returning a truthy or falsy value.

  This is distinct from a contract *violation*, and deliberately so: a violation
  means the assertion was evaluated and found false, while this means it could
  not be evaluated at all. Conflating the two would mask genuine bugs in a
  predicate — an assertion that raises is not evidence that the contract holds or
  fails, it is evidence the assertion is not total over its inputs.

      @pre valid: String.contains?(email, "@")
      def normalize(email), do: String.downcase(email)

      normalize(nil)
      ** (Bond.AssertionEvaluationError) precondition could not be evaluated for
         call to MyApp.normalize/1
      |   label: :valid
      |   assertion: String.contains?(email, "@")
      |   binding: [email: nil]
      |   raised: ** (FunctionClauseError) no function clause matching in String.contains?/2

  `:exception` is the original exception and `:original_stacktrace` its
  stacktrace, so the underlying failure is never lost. The rest of the fields
  carry the same contract metadata a violation would.

  See the "Assertions must be total" section of the
  [Writing sound assertions](writing-sound-assertions.md) guide for how to avoid
  this — usually by leading with a type check.
  """

  use Bond.AssertionError

  @impl Exception
  def message(%{kind: kind, module: module, function: {function, arity}} = error) do
    Bond.AssertionError.message(
      error,
      "#{kind_noun(kind)}#{Bond.AssertionError.attribution(error)} could not be evaluated " <>
        "#{preposition(kind)} #{inspect(module)}.#{function}/#{arity}"
    ) <> raised_line(error)
  end

  defp kind_noun(:precondition), do: "precondition"
  defp kind_noun(:postcondition), do: "postcondition"
  defp kind_noun(:state_invariant), do: "state invariant"
  defp kind_noun(:transition_invariant), do: "transition invariant"
  defp kind_noun(:invariant), do: "invariant"
  defp kind_noun(:check), do: "check"
  defp kind_noun(other), do: to_string(other)

  defp preposition(:precondition), do: "for call to"
  defp preposition(_other), do: "in"

  # The original failure is the actionable part, so it is rendered in full rather
  # than reduced to a type name.
  defp raised_line(%{exception: nil}), do: ""

  defp raised_line(%{exception: exception}) do
    "|   raised: ** (#{inspect(exception.__struct__)}) #{Exception.message(exception)}\n"
  end

  defp raised_line(_error), do: ""
end
