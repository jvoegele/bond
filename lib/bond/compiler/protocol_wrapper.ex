defmodule Bond.Compiler.ProtocolWrapper do
  @moduledoc internal: true
  @moduledoc """
  Generates the dispatch-layer wrapper for a protocol function carrying contracts.

  All generated code uses fully-qualified `Kernel.def`/`Kernel.defp`/`Kernel.defoverridable`
  because the protocol body excludes `Kernel.def`. The lifted assertion bodies reuse
  `Bond.Compiler.Assertion.assertions_body/3` (so the conditional-compilation chain, error
  structs, and stacktrace pruning are shared with ordinary contracts), and the runtime gate uses
  a compile default of `true` — global config and `Bond.Config` still toggle protocol contracts
  at runtime via `Bond.Runtime.Eval.should_evaluate?/3`.

  See `Bond.Protocol` for the "Option B" design (wrap the single dispatch function, once, at
  `@before_compile`).
  """

  alias Bond.Compiler.Assertion

  @doc """
  Builds the `{:__block__, _, _}` of statements that wrap one protocol function: the
  `defoverridable`, the redefined dispatch `def` that checks pre/super/post, and the lifted
  precondition/postcondition `defp`s.
  """
  def build_wrapper(protocol, name, arity, arg_names, pre, post) do
    arg_vars = Enum.map(arg_names, &Macro.var(&1, nil))
    result_var = Macro.var(:result, nil)
    subject = List.first(arg_vars)
    function_info = {name, arity}

    pre_fn = :"__bond_protocol_pre_#{name}_#{arity}__"
    post_fn = :"__bond_protocol_post_#{name}_#{arity}__"
    pre_chain = if pre != [], do: true, else: :purge

    wrapper_body =
      if(pre != [], do: [pre_eval_stmt(protocol, subject, pre_fn, arg_vars)], else: []) ++
        [quote(do: unquote(result_var) = super(unquote_splicing(arg_vars)))] ++
        if(post != [],
          do: [post_eval_stmt(protocol, subject, post_fn, arg_vars, pre_chain)],
          else: []
        ) ++
        [result_var]

    statements =
      [
        quote do
          Kernel.defoverridable([{unquote(name), unquote(arity)}])

          Kernel.def unquote(name)(unquote_splicing(arg_vars)) do
            (unquote_splicing(wrapper_body))
          end
        end
      ] ++
        if pre != [] do
          [
            quote do
              Kernel.defp unquote(pre_fn)(unquote_splicing(arg_vars)) do
                unquote(Assertion.assertions_body(pre, function_info))
              end
            end
          ]
        else
          []
        end ++
        if post != [] do
          [
            quote do
              Kernel.defp unquote(post_fn)(unquote_splicing(arg_vars), unquote(result_var)) do
                unquote(Assertion.assertions_body(post, function_info))
              end
            end
          ]
        else
          []
        end

    {:__block__, [], statements}
  end

  defp pre_eval_stmt(protocol, subject, pre_fn, arg_vars) do
    quote do
      if Bond.Runtime.Eval.should_evaluate?(:preconditions, true) do
        Bond.Runtime.Eval.evaluate_protocol_assertions(unquote(protocol), unquote(subject), fn ->
          unquote(pre_fn)(unquote_splicing(arg_vars))
        end)
      end
    end
  end

  defp post_eval_stmt(protocol, subject, post_fn, arg_vars, pre_chain) do
    result_var = Macro.var(:result, nil)
    chain = Macro.escape(%{preconditions: pre_chain})

    quote do
      if Bond.Runtime.Eval.should_evaluate?(:postconditions, true, unquote(chain)) do
        Bond.Runtime.Eval.evaluate_protocol_assertions(unquote(protocol), unquote(subject), fn ->
          unquote(post_fn)(unquote_splicing(arg_vars), unquote(result_var))
        end)
      end
    end
  end
end
