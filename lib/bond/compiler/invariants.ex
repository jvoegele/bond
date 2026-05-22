defmodule Bond.Compiler.Invariants do
  @moduledoc internal: true
  @moduledoc """
  Emission logic for `@invariant`s.

  Lives in its own module (rather than inside `Bond.Compiler.AnnotatedFunction`) for two
  reasons:

    1. **Separation of concerns.** `AnnotatedFunction` owns the data model — clauses,
       per-function assertions, doc attributes, the override decision. The invariant emission
       is its own concern: detecting the struct-bearing argument, building the lifted defp,
       producing the pre-/post-invariant call sites. Keeping these apart makes both files
       easier to read.

    2. **Compilation order.** Growing `AnnotatedFunction` past a certain size shifted it
       later in the parallel-compile schedule, which raced with the test-support modules
       starting their own compilation. Splitting the emission logic out of
       `AnnotatedFunction` keeps that file smaller and avoids the race.

  The functions here are called from `Bond.Compiler.AnnotatedFunction.apply_contract/2` at
  the user module's `__before_compile__` time, and produce AST that's spliced into the
  user's module override clause.
  """

  alias Bond.Compiler.Assertion

  @typedoc """
  Result of analysing a function head for an invariant-bearing argument.

    * `{:ok, var_name}` — the function pattern-matches `%__MODULE__{} = name` (in either
      order) or has an `is_struct(name, __MODULE__)` guard. `name` is the bound variable
      that the pre-invariant check should run against.
    * `{:warn, :unbound_destructure}` — the function destructures `%__MODULE__{...}` but
      doesn't bind the whole struct to a variable. Pre-invariant check is skipped.
    * `:none` — neither pattern nor guard mentions `%__MODULE__{}`. Skip silently.
  """
  @type struct_arg_result :: {:ok, atom()} | {:warn, atom()} | :none

  @doc """
  Inspects a function's parameter list and guards for a binding to this module's struct.

  Only matches the `%__MODULE__{}` form. Fully-qualified module patterns (`%MyMod{}`) and
  aliased forms are not recognised in 0.13.0 — users who want invariant pre-checks should
  use `__MODULE__` idiomatically.
  """
  @spec find_struct_arg([Macro.t()], [Macro.t()]) :: struct_arg_result()
  def find_struct_arg(params, guards) when is_list(params) and is_list(guards) do
    cond do
      name = bound_struct_param(params) -> {:ok, name}
      name = is_struct_guard_var(guards) -> {:ok, name}
      unbound_struct_param?(params) -> {:warn, :unbound_destructure}
      true -> :none
    end
  end

  @typedoc """
  Descriptor for a single struct-bearing parameter in a function head.

    * `{:bound, var_name, param_index}` — the parameter is bound to a variable in the head
      (via `%__MODULE__{} = name`, `name = %__MODULE__{}`, or a bare `name` with an
      `is_struct(name, __MODULE__)` guard somewhere in the guard list, including inside
      compound `and`/`or` expressions). `param_index` is 0-based.

    * `{:destructure, param_index}` — the parameter destructures `%__MODULE__{...}` but
      does not bind the whole struct to a variable. Invariant emission rewrites the
      override clause head at this position to capture the struct under a generated name.
  """
  @type struct_param ::
          {:bound, atom(), non_neg_integer()}
          | {:destructure, non_neg_integer()}

  @doc """
  Finds every struct-bearing parameter in a function head, in left-to-right order.

  Returns a list of `t:struct_param/0` descriptors. Returns `[]` when no parameter and
  no guard mentions the module's struct.

  Recognised patterns:

    * `%__MODULE__{} = name` (or destructure-and-bind, e.g. `%__MODULE__{field: x} = name`)
    * `name = %__MODULE__{}` (reversed)
    * bare `name` plus `is_struct(name, __MODULE__)` somewhere in the guards, including
      inside arbitrary nesting of `and` / `or`
    * `%__MODULE__{...}` destructure with no `= name` — returned as `{:destructure, idx}`

  Multiple struct parameters in the same head (e.g. `def merge(%__MODULE__{} = a,
  %__MODULE__{} = b)`) all appear in the result.

  Fully-qualified module patterns (`%MyMod{}`) and aliased forms are not recognised —
  invariants are scoped to the struct's own defining module, so `__MODULE__` is the
  idiomatic form.
  """
  @spec detect_struct_params([Macro.t()], [Macro.t()]) :: [struct_param()]
  def detect_struct_params(params, guards) when is_list(params) and is_list(guards) do
    guard_vars = collect_guard_struct_vars(guards)

    params
    |> Enum.with_index()
    |> Enum.flat_map(fn {param, idx} ->
      case classify_param(param, guard_vars) do
        {:bound, name} -> [{:bound, name, idx}]
        :destructure -> [{:destructure, idx}]
        :none -> []
      end
    end)
  end

  @doc """
  Resolves the per-function invariant mode given the per-module config value and the
  annotated function's `:kind` and `:invariants` list.

  Returns `:purge` when:

    * the user explicitly purged invariants, OR
    * the function is `defp` (private functions are exempt by the Eiffel convention), OR
    * the module has no `@invariant`s registered.

  Otherwise returns the supplied `true`/`false` mode unchanged.
  """
  @spec resolve_mode(mode :: Bond.Compiler.AnnotatedFunction.mode(), :def | :defp, list()) ::
          Bond.Compiler.AnnotatedFunction.mode()
  def resolve_mode(:purge, _kind, _invariants), do: :purge
  def resolve_mode(_value, :defp, _invariants), do: :purge
  def resolve_mode(_value, _kind, []), do: :purge
  def resolve_mode(value, _kind, _invariants) when value in [true, false], do: value

  @doc """
  Picks the variable name to pre-check (if any) given the resolved mode and a function
  clause. Returns the var-name atom on a clean detection, or `nil` when invariants are
  purged or the function head doesn't expose a struct arg we can pre-check.
  """
  @spec struct_arg(Bond.Compiler.AnnotatedFunction.mode(), term()) :: atom() | nil
  def struct_arg(:purge, _clause), do: nil

  def struct_arg(_mode, clause) do
    case find_struct_arg(clause.params || [], clause.guards || []) do
      {:ok, name} -> name
      {:warn, :unbound_destructure} -> nil
      :none -> nil
    end
  end

  @doc """
  Emits the pre-invariant statements that go at the *start* of the override body.

  Gated on `Bond.Runtime.Eval.should_evaluate?/2`. Returns an empty list when the kind is
  purged or when there's no struct arg to check against.
  """
  @spec pre_invariant_stmts(
          atom(),
          atom() | nil,
          Bond.Compiler.AnnotatedFunction.mode(),
          Bond.Compiler.AnnotatedFunction.mode(),
          Bond.Compiler.AnnotatedFunction.mode()
        ) :: [Macro.t()]
  def pre_invariant_stmts(_name, _struct_arg, :purge, _pre_mode, _post_mode), do: []
  def pre_invariant_stmts(_name, nil, _mode, _pre_mode, _post_mode), do: []

  def pre_invariant_stmts(name, struct_arg, mode, pre_mode, post_mode) do
    arg_var = Macro.var(struct_arg, nil)
    chain = %{preconditions: pre_mode, postconditions: post_mode}

    [
      quote do
        if Bond.Runtime.Eval.should_evaluate?(
             :invariants,
             unquote(mode),
             unquote(Macro.escape(chain))
           ) do
          Bond.Runtime.Eval.evaluate_invariants(fn ->
            unquote(name)(unquote(arg_var))
          end)
        end
      end
    ]
  end

  @doc """
  Emits the post-invariant case-extraction statements that go *after* the postconditions
  and before the return.

  Matches both `%<struct_module>{}` and `{:ok, %<struct_module>{}}` return shapes; anything
  else falls through to a no-op. The same lifted invariants defp used by the pre-check
  runs against the extracted value. The struct module is unquoted into the user's module
  rather than spelled `%__MODULE__{}` inside the quote, to avoid a deferred-`__MODULE__`
  reference that confuses parallel compilation.
  """
  @spec post_invariant_stmts(
          atom(),
          Bond.Compiler.AnnotatedFunction.mode(),
          module(),
          Bond.Compiler.AnnotatedFunction.mode(),
          Bond.Compiler.AnnotatedFunction.mode()
        ) :: [Macro.t()]
  def post_invariant_stmts(_name, :purge, _struct_module, _pre_mode, _post_mode), do: []

  def post_invariant_stmts(name, mode, struct_module, pre_mode, post_mode) do
    chain = %{preconditions: pre_mode, postconditions: post_mode}

    [
      quote do
        case var!(result) do
          %unquote(struct_module){} = __bond_post_value__ ->
            if Bond.Runtime.Eval.should_evaluate?(
                 :invariants,
                 unquote(mode),
                 unquote(Macro.escape(chain))
               ) do
              Bond.Runtime.Eval.evaluate_invariants(fn ->
                unquote(name)(__bond_post_value__)
              end)
            end

          {:ok, %unquote(struct_module){} = __bond_post_value__} ->
            if Bond.Runtime.Eval.should_evaluate?(
                 :invariants,
                 unquote(mode),
                 unquote(Macro.escape(chain))
               ) do
              Bond.Runtime.Eval.evaluate_invariants(fn ->
                unquote(name)(__bond_post_value__)
              end)
            end

          _ ->
            :ok
        end
      end
    ]
  end

  @doc """
  Builds the lifted `defp __bond_invariants__<fun>__<arity>(value)` that the pre- and
  post-invariant call sites delegate to. Returns `nil` when invariants are purged.
  """
  @spec build_lifted_defp(
          atom(),
          [Assertion.t(:invariant)],
          Assertion.function_info(),
          Macro.Env.t(),
          Bond.Compiler.AnnotatedFunction.mode()
        ) :: Macro.t() | nil
  def build_lifted_defp(_name, _invariants, _function_info, _env, :purge), do: nil

  def build_lifted_defp(name, invariants, function_info, env, _mode) do
    body = Assertion.invariants_body(invariants, function_info)

    quote file: env.file, line: env.line do
      defp unquote(name)(var!(bond_invariant_value)) do
        unquote(body)
      end
    end
  end

  # ---- AST helpers (moved from AnnotatedFunction in step 6) ----

  defp bound_struct_param(params) do
    Enum.find_value(params, fn
      {:=, _, [{:%, _, [{:__MODULE__, _, _}, _]}, {var, _, ctx}]}
      when is_atom(var) and is_atom(ctx) ->
        var

      {:=, _, [{var, _, ctx}, {:%, _, [{:__MODULE__, _, _}, _]}]}
      when is_atom(var) and is_atom(ctx) ->
        var

      _ ->
        nil
    end)
  end

  defp unbound_struct_param?(params) do
    Enum.any?(params, fn
      {:%, _, [{:__MODULE__, _, _}, _]} -> true
      _ -> false
    end)
  end

  defp is_struct_guard_var(guards) do
    Enum.find_value(guards, &extract_is_struct_var/1)
  end

  defp extract_is_struct_var({:is_struct, _, [{var, _, ctx}, {:__MODULE__, _, _}]})
       when is_atom(var) and is_atom(ctx) do
    var
  end

  defp extract_is_struct_var({:and, _, [left, right]}) do
    extract_is_struct_var(left) || extract_is_struct_var(right)
  end

  defp extract_is_struct_var(_), do: nil

  # ---- Helpers for detect_struct_params/2 (S1: subject-binding work) ----

  defp classify_param(param, guard_vars) do
    case param do
      {:=, _, [{:%, _, [{:__MODULE__, _, _}, _]}, {var, _, ctx}]}
      when is_atom(var) and is_atom(ctx) ->
        {:bound, var}

      {:=, _, [{var, _, ctx}, {:%, _, [{:__MODULE__, _, _}, _]}]}
      when is_atom(var) and is_atom(ctx) ->
        {:bound, var}

      {var, _, ctx} when is_atom(var) and is_atom(ctx) ->
        if MapSet.member?(guard_vars, var), do: {:bound, var}, else: :none

      {:%, _, [{:__MODULE__, _, _}, _]} ->
        :destructure

      _ ->
        :none
    end
  end

  defp collect_guard_struct_vars(guards) do
    guards
    |> Enum.flat_map(&walk_guard_for_is_struct/1)
    |> MapSet.new()
  end

  defp walk_guard_for_is_struct({:is_struct, _, [{var, _, ctx}, {:__MODULE__, _, _}]})
       when is_atom(var) and is_atom(ctx) do
    [var]
  end

  defp walk_guard_for_is_struct({op, _, [left, right]}) when op in [:and, :or] do
    walk_guard_for_is_struct(left) ++ walk_guard_for_is_struct(right)
  end

  defp walk_guard_for_is_struct(_), do: []
end
