defmodule Bond.AssertionError do
  @moduledoc internal: true

  defmacro __using__(_opts) do
    quote generated: true do
      defexception [
        :label,
        :expression,
        :file,
        :line,
        :module,
        :function,
        :binding,
        :source_behaviour
      ]

      @typedoc """
      The `#{inspect(__MODULE__)}` exception type.

      `:source_behaviour` is the behaviour module an inherited contract came from (see
      `Bond.Behaviour`), or `nil` for a contract declared directly on the function.
      """
      @type t :: %__MODULE__{
              label: Bond.assertion_label(),
              expression: Bond.assertion_expression(),
              file: Path.t(),
              line: integer(),
              module: module(),
              function: {String.t(), non_neg_integer()},
              binding: keyword(),
              source_behaviour: module() | nil
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
          expression: assertion.code,
          file: assertion_env.file,
          line: assertion_env.line,
          module: assertion_env.module,
          function: function_env.function,
          binding: binding,
          source_behaviour: Map.get(assertion, :source_behaviour)
        }
      end
    end
  end

  @doc """
  Returns a parenthetical attribution like `" (inherited from Ledger)"` when `source_behaviour`
  is a module, or `""` when it is `nil`. Used by the precondition/postcondition messages to
  name the behaviour an inherited contract came from.
  """
  def attribution(nil), do: ""
  def attribution(source_behaviour), do: " (inherited from #{inspect(source_behaviour)})"

  def message(error, headline) do
    location =
      case {error.file, error.line} do
        {nil, _} -> nil
        {file, nil} -> file
        {file, line} -> "#{file}:#{line}"
      end

    location_line = if location, do: "|   at: #{location}\n", else: ""

    """
    #{headline}
    #{location_line}|   label: #{inspect(error.label)}
    |   assertion: #{error.expression}
    |   binding: #{format_binding(error.binding)}
    """
  end

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
      "precondition#{Bond.AssertionError.attribution(error.source_behaviour)} failed " <>
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
      "postcondition#{Bond.AssertionError.attribution(error.source_behaviour)} failed " <>
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
  Exception raised when an `@invariant` for a struct module is violated.

  Invariants are checked when a public function in the struct's defining module receives or
  returns a value of the struct. The error's `:function` field identifies the function the
  invariant was checked around; `:module` is always the struct's module.
  """

  use Bond.AssertionError

  @impl Exception
  def message(%{module: module, function: {function, arity}} = error) do
    Bond.AssertionError.message(
      error,
      "invariant violated around #{inspect(module)}.#{function}/#{arity}"
    )
  end
end
