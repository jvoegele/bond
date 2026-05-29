defmodule Bond.Compiler.FunctionDefinition do
  @moduledoc internal: true
  @moduledoc """
  Struct containing information about a function definition at compile time.

  This struct represents a single `def` or `defp` at compile time, so there will be separate
  instances of the struct for each clause of a multi-clause function.
  """

  defstruct env: nil,
            kind: nil,
            module: nil,
            fun: nil,
            arity: nil,
            params: nil,
            guards: nil,
            body: nil,
            warn_skipped_invariants_override: nil,
            external_override?: false

  @type doc_attribute_value :: String.t() | Keyword.t()
  @type doc_attribute :: {meta :: Keyword.t(), value :: doc_attribute_value()}

  @type kind :: :def | :defp

  @type function_parameters :: list()
  @type function_guards :: list()
  @type function_body :: list() | nil

  @type clause :: {Macro.Env.t(), function_parameters(), function_guards(), function_body()}

  @type t :: %__MODULE__{
          env: Macro.Env.t(),
          kind: kind(),
          module: module(),
          fun: atom(),
          params: list(),
          guards: list(),
          body: list() | nil,
          warn_skipped_invariants_override: nil | boolean(),
          external_override?: boolean()
        }

  @spec new(
          env :: Macro.Env.t(),
          kind :: kind(),
          fun :: atom(),
          params :: list(),
          guards :: list(),
          body :: list() | nil
        ) :: t()
  def new(%Macro.Env{} = env, kind, fun, params, guards, body) when kind in [:def, :defp] do
    %__MODULE__{
      env: env,
      kind: kind,
      module: env.module,
      fun: fun,
      arity: length(params),
      params: params,
      guards: guards,
      body: body
    }
  end

  def mfa(%__MODULE__{module: module, fun: function, params: params}) do
    {module, function, length(params)}
  end

  def mfa(_), do: nil

  @doc """
  Records the per-function `@bond_warn_skipped_invariants` override captured at
  `__on_definition__` time. `nil` means no override was set; `true`/`false`
  overrides the module/global config for this single function.
  """
  @spec put_warn_skipped_invariants_override(t(), nil | boolean()) :: t()
  def put_warn_skipped_invariants_override(%__MODULE__{} = fd, override)
      when override == nil or is_boolean(override) do
    %{fd | warn_skipped_invariants_override: override}
  end

  @doc """
  Records whether this clause was an externally-generated override at `__on_definition__`
  time — i.e. the function was `defoverridable` and is now being redefined by another library
  (Norm's `@contract`, the `decorator` library, etc.). Such clauses are wrappers, not user
  contract sites; the FSM ignores them when they re-appear for an already-tracked function.

  See `Bond.Compiler.__on_definition__/6` for how this is detected (`Module.overridable?/2`).
  """
  @spec put_external_override(t(), boolean()) :: t()
  def put_external_override(%__MODULE__{} = fd, external_override?)
      when is_boolean(external_override?) do
    %{fd | external_override?: external_override?}
  end

  @doc "Returns whether this clause was an externally-generated override (see `put_external_override/2`)."
  @spec external_override?(t()) :: boolean()
  def external_override?(%__MODULE__{external_override?: value}), do: value
end
