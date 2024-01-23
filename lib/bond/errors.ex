defmodule Bond.AssertionError do
  @moduledoc internal: true

  defmacro __using__(_opts) do
    quote generated: true do
      defexception [:label, :expression, :assertion_env, :function_env, :binding]

      @typedoc """
      The `#{inspect(__MODULE__)}` exception type.
      """
      @type t :: %__MODULE__{
              label: Bond.assertion_label(),
              expression: Bond.assertion_expression(),
              assertion_env: Bond.env(),
              function_env: Bond.env(),
              binding: keyword()
            }

      @impl Exception
      def exception(opts) do
        assertion = Keyword.fetch!(opts, :assertion)
        function_env = opts |> Keyword.fetch!(:env) |> Bond.Env.new()
        {function, arity} = function_env.function
        binding = Keyword.fetch!(opts, :binding)

        error = %__MODULE__{
          label: assertion.label,
          expression: Macro.to_string(assertion.expression),
          assertion_env: assertion.definition_env,
          function_env: function_env,
          binding: binding
        }
      end
    end
  end

  def message(error, headline) do
    """
    #{headline}
    |   label: #{inspect(error.label)}
    |   assertion: #{Macro.to_string(error.expression)}
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
  def message(%{function_env: %{module: module, function: {function, arity}}} = error) do
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
  def message(%{function_env: %{module: module, function: {function, arity}}} = error) do
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
  def message(%{function_env: %{module: module, function: {function, arity}}} = error) do
    Bond.AssertionError.message(
      error,
      "check failed in #{inspect(module)}.#{function}/#{arity}"
    )
  end
end
