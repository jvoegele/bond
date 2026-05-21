defmodule Bond.Compiler.Assertion do
  @moduledoc internal: true
  @moduledoc """
  Struct representing an assertion that appears as part of contract specifications, such as in
  preconditions or postconditions attached to functions.

  Assertions are constructed at compile-time and as such the fields in this struct are quoted
  expressions or compile-time environment data. At run-time, the assertion `:expression` is
  evaluated by unquoting it in the context of the function to which the assertion is attached.
  """

  alias __MODULE__

  @enforce_keys [:id, :expression, :kind, :definition_env, :meta]
  defstruct [:id, :label, :expression, :code, :kind, :definition_env, :meta]

  @type t :: t(Bond.assertion_kind())

  @type t(kind) :: %__MODULE__{
          id: String.t(),
          label: Bond.assertion_label(),
          expression: Bond.assertion_expression(),
          code: String.t(),
          kind: kind,
          definition_env: Macro.Env.t(),
          meta: list()
        }

  @type function_info :: {atom(), non_neg_integer()}

  @assertion_errors %{
    precondition: Bond.PreconditionError,
    postcondition: Bond.PostconditionError,
    check: Bond.CheckError
  }

  defguard is_assertion_expression(expression)
           when is_tuple(expression) and
                  tuple_size(expression) == 3 and
                  is_atom(elem(expression, 0)) and is_list(elem(expression, 1)) and
                  is_list(elem(expression, 2))

  @doc """
  Construct a new `t:t/0` struct.

  Each assertion is tagged with a unique random `:id` so that it has a stable identity that
  survives macro expansion. The `:code` field is the human-readable form of the quoted
  `expression`, suitable for inclusion in error messages and generated documentation.
  """
  def new(kind, label, expression, %Macro.Env{} = env \\ __ENV__, meta \\ [])
      when is_assertion_expression(expression) do
    %__MODULE__{
      id: generate_unique_id(),
      kind: kind,
      label: label,
      expression: expression,
      code: Macro.to_string(expression),
      definition_env: env,
      meta: meta
    }
  end

  @doc """
  Returns a quoted anonymous function that, when called, evaluates each of the given
  `assertions` in order.

  On the first assertion failure the function throws `{:assertion_failure, info}`, where
  `info` is a map containing enough metadata to construct a `Bond.PreconditionError` /
  `Bond.PostconditionError` / `Bond.CheckError` struct, plus the runtime `binding()` from
  inside the wrapper function.

  `function_info` must be a `{name, arity}` tuple identifying the function the assertions are
  attached to; it is embedded in the error info so error messages can report the calling
  function's MFA.

  The body of the function imports `Bond.Predicates` so operators like `~>` and `|||` are
  available to assertion expressions.
  """
  @spec create_assertions_function([t()], function_info()) :: Macro.t()
  def create_assertions_function(assertions, function_info)
      when is_list(assertions) and is_tuple(function_info) do
    assertions_eval =
      for %Assertion{expression: expression, definition_env: assertion_env} = assertion <-
            assertions do
        assertion_info = %{
          kind: assertion.kind,
          label: assertion.label,
          expression: assertion.code,
          file: assertion_env.file,
          line: assertion_env.line,
          module: assertion_env.module,
          function: function_info
        }

        quote do
          if unquote(expression) do
            :ok
          else
            assertion_info = unquote(Macro.escape(assertion_info))
            # Sort the binding so failure messages are stable across runs and easy to diff.
            throw({:assertion_failure, Map.put(assertion_info, :binding, Enum.sort(binding()))})
          end
        end
      end

    quote do
      fn ->
        import Bond.Predicates

        unquote_splicing(assertions_eval)
      end
    end
  end

  @doc """
  Returns a quoted expression that, when unquoted, evaluates the given `assertion` inline.

  Used by `Bond.check/1,2`, which (unlike `@pre`/`@post`) is evaluated at the call site and
  returns the value of the assertion expression on success.
  """
  def quoted_eval(%__MODULE__{kind: kind, expression: expression} = assertion) do
    imports = imports(kind)
    exception = Map.fetch!(@assertion_errors, kind)

    quote do
      unquote(imports)

      if value = unquote(expression) do
        value
      else
        raise unquote(exception),
          assertion: unquote(Macro.escape(assertion)),
          env: __ENV__,
          binding: binding()
      end
    end
  end

  @id_chars ~c"0123456789abcdefghijklmnopqrstuvwxyz"

  defp generate_unique_id do
    for _ <- 1..32, into: "", do: <<Enum.random(@id_chars)>>
  end

  defp imports(kind) when kind in [:precondition, :postcondition, :check] do
    quote do
      import Bond.Predicates
    end
  end

  defimpl String.Chars do
    def to_string(%Bond.Compiler.Assertion{label: label, expression: expression, kind: kind}) do
      "#{kind}(#{inspect(label)}) => #{Macro.to_string(expression)}"
    end
  end
end
