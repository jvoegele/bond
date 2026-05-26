defmodule Bond.Compiler.ClauseWrapper do
  @moduledoc internal: true
  @moduledoc """
  Per-clause wrapper emission for Bond-contracted functions.

  Each user clause of a contracted function gets one wrapper clause that:

    1. Pre-invariant check (if any).
    2. Pre-eval call to the lifted precondition defp (if any).
    3. `old(...)` assignments at function entry.
    4. `super(...)` delegating to the user's original clause.
    5. Post-eval call to the lifted postcondition defp (if any).
    6. Post-invariant check on the captured result (if any).
    7. Return the captured result.

  Bond emits ONE set of lifted assertion defps per function (since contract
  semantics are uniform across clauses), and ONE wrapper clause per user clause
  (since multi-clause dispatch is preserved by reproducing each clause's
  pattern in the wrapper head).

  Lives in its own module so `Bond.Compiler.AnnotatedFunction` — which is on
  the FSM's hot path via `AnnotatedFunction.new/1` — stays small. See the
  compile-order gotcha memory.
  """

  alias Bond.Compiler.Invariants

  @typedoc """
  Per-function context shared across every clause wrapper for one Bond-
  contracted function. Bundles the lifted defp names, the resolved per-kind
  modes, the precompiled `old(...)` context, the function's MFA, and the
  struct module (used for post-invariant case-extraction).
  """
  @type context :: %{
          required(:fun) => atom(),
          required(:arity) => non_neg_integer(),
          required(:kind) => :def | :defp,
          required(:struct_module) => module(),
          required(:pre_mode) => Bond.Compiler.AnnotatedFunction.mode(),
          required(:post_mode) => Bond.Compiler.AnnotatedFunction.mode(),
          required(:inv_mode) => Bond.Compiler.AnnotatedFunction.mode(),
          required(:pre_fn_name) => atom(),
          required(:post_fn_name) => atom(),
          required(:inv_fn_name) => atom(),
          required(:old_pairs) => list(),
          required(:old_assignments) => [Macro.t()]
        }

  @doc """
  Builds one wrapper clause AST for the given `clause`, using the per-function
  context. Returns the `def`/`defp` head + body as a quoted form ready to be
  spliced alongside the lifted assertion defps inside the override block.
  """
  @spec build_wrapper(term(), context()) :: Macro.t()
  def build_wrapper(clause, %{} = context) do
    clean_params = strip_default_args(clause.params)

    {struct_params, head_params, super_args} =
      Invariants.params_split(clean_params, clause, context.inv_mode)

    pre_invariant_stmts =
      Invariants.all_pre_invariant_stmts(
        context.inv_fn_name,
        struct_params,
        context.inv_mode,
        context.pre_mode,
        context.post_mode
      )

    post_invariant_stmts =
      Invariants.post_invariant_stmts(
        context.inv_fn_name,
        context.inv_mode,
        context.struct_module,
        context.pre_mode,
        context.post_mode
      )

    body_stmts =
      build_override_body(
        super_args,
        context.pre_fn_name,
        context.post_fn_name,
        context.old_assignments,
        context.old_pairs,
        context.pre_mode,
        context.post_mode,
        pre_invariant_stmts,
        post_invariant_stmts
      )

    kind = context.kind
    fun = context.fun

    quote do
      unquote(kind)(unquote(fun)(unquote_splicing(head_params))) do
        (unquote_splicing(body_stmts))
      end
    end
  end

  @doc """
  Strips default-arg syntax (`x \\\\ default`) from a param list, leaving the
  bare patterns. Elixir's auto-generated forwarding clauses for default args
  dispatch by name + arity, so they end up calling Bond's override regardless
  of which arity the caller used.
  """
  @spec strip_default_args([Macro.t()]) :: [Macro.t()]
  def strip_default_args(params) when is_list(params) do
    Enum.map(params, fn
      {:\\, _meta, [param, _default]} -> param
      other -> other
    end)
  end

  # --- Body assembly: pre/super/post statements ---

  defp build_override_body(
         call_params,
         pre_fn_name,
         post_fn_name,
         old_assignments,
         old_pairs,
         pre_mode,
         post_mode,
         pre_invariant_stmts,
         post_invariant_stmts
       ) do
    pre_stmts = pre_eval_stmts(call_params, pre_fn_name, pre_mode)
    super_call = quote(do: var!(result) = super(unquote_splicing(call_params)))
    post_stmts = post_eval_stmts(call_params, post_fn_name, old_pairs, post_mode, pre_mode)
    return_stmt = quote(do: var!(result))

    pre_invariant_stmts ++
      pre_stmts ++
      old_assignments ++
      [super_call] ++ post_stmts ++ post_invariant_stmts ++ [return_stmt]
  end

  defp pre_eval_stmts(_call_params, _name, :purge), do: []

  defp pre_eval_stmts(call_params, name, mode) do
    [
      quote do
        if Bond.Runtime.Eval.should_evaluate?(:preconditions, unquote(mode)) do
          Bond.Runtime.Eval.evaluate_preconditions(fn ->
            unquote(name)(unquote_splicing(call_params))
          end)
        end
      end
    ]
  end

  defp post_eval_stmts(_call_params, _name, _old_pairs, :purge, _pre_mode), do: []

  defp post_eval_stmts(call_params, name, old_pairs, mode, pre_mode) do
    old_args = for {var, _expression} <- old_pairs, do: quote(do: var!(unquote(var)))
    args = call_params ++ [quote(do: var!(result)) | old_args]
    chain = %{preconditions: pre_mode}

    [
      quote do
        if Bond.Runtime.Eval.should_evaluate?(
             :postconditions,
             unquote(mode),
             unquote(Macro.escape(chain))
           ) do
          Bond.Runtime.Eval.evaluate_postconditions(fn ->
            unquote(name)(unquote_splicing(args))
          end)
        end
      end
    ]
  end
end
