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
            warn_unavailable_preconditions_override: nil,
            external_override?: false

  @typedoc """
  One buffered `@doc` attribute: its metadata (carrying the source `:line`, which is how the FSM
  associates it with the definition that follows) and its value — a docstring, `false`, or a
  metadata keyword list.
  """
  @type doc_attribute :: {meta :: Keyword.t(), value :: String.t() | false | Keyword.t()}

  @type kind :: :def | :defp

  @type t :: %__MODULE__{
          env: Macro.Env.t(),
          kind: kind(),
          module: module(),
          fun: atom(),
          params: list(),
          guards: list(),
          body: list() | nil,
          warn_skipped_invariants_override: nil | boolean(),
          warn_unavailable_preconditions_override: nil | boolean(),
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
      params: Enum.map(params, &strip_foreign_calls/1),
      guards: guards,
      body: body
    }
  end

  # A library that overrides `def`/`defp` can rewrite a head before Bond ever sees it, leaving a
  # macro CALL sitting in the parameter AST that `@on_definition` hands us. `Phoenix.Component`
  # does exactly this: every arity-1 head gets its argument wrapped in
  # `Phoenix.Component.Declarative.__pattern__!/2`, whose body opens with
  # `{name, 1} = __CALLER__.function`.
  #
  # Bond replays these parameters in generated heads of a DIFFERENT arity — the lifted
  # `__bond_postconditions__<fun>__<arity>` defp takes the arguments plus `result` — so such a
  # macro expands with the wrong function in caller position and fails on an internal tuple,
  # naming neither Bond nor arity (#134).
  #
  # Expanding it here instead is not an option: these macros have compile-time side effects
  # (Phoenix's registers the component and its attr docs), and running one a second time
  # duplicates them. So the call is *stripped* rather than evaluated. Bond needs only the binding
  # structure of a parameter, and a call in pattern position binds nothing itself — whatever it
  # expands to is derived from its arguments, so the argument that is itself a pattern is what
  # Bond keeps. The real head still carries the macro and still enforces whatever it imposes;
  # Bond's copy only has to agree about names.
  defp strip_foreign_calls({:=, meta, [left, right]}) do
    case {foreign_call?(left), foreign_call?(right)} do
      # `Mod.macro!(_) = var` — the binding side is the whole of what Bond needs.
      {true, false} -> strip_foreign_calls(right)
      {false, true} -> strip_foreign_calls(left)
      _ -> {:=, meta, [strip_foreign_calls(left), strip_foreign_calls(right)]}
    end
  end

  defp strip_foreign_calls({{:., _, [_mod, _fun]}, meta, args} = call) do
    if foreign_call?(call) do
      case Enum.filter(args, &pattern_like?/1) do
        [pattern] -> strip_foreign_calls(pattern)
        # Nothing pattern-shaped to keep, or no way to choose: bind nothing.
        _ -> {:_, meta, nil}
      end
    else
      call
    end
  end

  defp strip_foreign_calls({left, meta, right}) when is_list(right),
    do: {strip_foreign_calls(left), meta, Enum.map(right, &strip_foreign_calls/1)}

  defp strip_foreign_calls({left, right}),
    do: {strip_foreign_calls(left), strip_foreign_calls(right)}

  defp strip_foreign_calls(list) when is_list(list), do: Enum.map(list, &strip_foreign_calls/1)
  defp strip_foreign_calls(other), do: other

  # Only remote calls. A local call in pattern position is either a Bond-generated construct or
  # already a compile error in the user's own head, and pinned/struct/sigil forms are not calls.
  defp foreign_call?({{:., _, [_mod, _fun]}, _, args}) when is_list(args), do: true
  defp foreign_call?(_), do: false

  # Anything that can bind or match structurally, as opposed to an option atom or literal the
  # wrapping macro takes as configuration.
  defp pattern_like?({:_, _, ctx}) when is_atom(ctx), do: true
  defp pattern_like?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp pattern_like?({:%, _, _}), do: true
  defp pattern_like?({:%{}, _, _}), do: true
  defp pattern_like?({:{}, _, _}), do: true
  defp pattern_like?({:=, _, _}), do: true
  defp pattern_like?({:<<>>, _, _}), do: true
  defp pattern_like?(list) when is_list(list), do: true
  defp pattern_like?({_, _}), do: true
  defp pattern_like?(_), do: false

  @spec mfa(t()) :: mfa()
  def mfa(%__MODULE__{module: module, fun: function, params: params}) do
    {module, function, length(params)}
  end

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
  Records the per-function `@bond_warn_unavailable_preconditions` tri-state (#92), the
  same shape as `put_warn_skipped_invariants_override/2`.
  """
  @spec put_warn_unavailable_preconditions_override(t(), nil | boolean()) :: t()
  def put_warn_unavailable_preconditions_override(%__MODULE__{} = fd, override)
      when is_nil(override) or is_boolean(override) do
    %{fd | warn_unavailable_preconditions_override: override}
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
