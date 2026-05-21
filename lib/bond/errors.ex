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
        :binding
      ]

      @typedoc """
      The `#{inspect(__MODULE__)}` exception type.
      """
      @type t :: %__MODULE__{
              label: Bond.assertion_label(),
              expression: Bond.assertion_expression(),
              file: Path.t(),
              line: integer(),
              module: module(),
              function: {String.t(), non_neg_integer()},
              binding: keyword()
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
          binding: binding
        }
      end
    end
  end

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
    |   binding: #{inspect(error.binding)}
    """
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
      "precondition failed for call to #{inspect(module)}.#{function}/#{arity}"
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
      "postcondition failed in #{inspect(module)}.#{function}/#{arity}"
    )
  end
end

defmodule Bond.CheckError do
  @moduledoc """
  Exception raised when a `Bond.check/2` assertion fails.
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
