defmodule Bond.Contracts do
  @moduledoc internal: true
  @moduledoc """
  Internal helper module for defining contracts.
  """

  alias Bond.Assertion
  alias Bond.CompileStateFSM, as: FSM
  alias Bond.OldExpression

  def init(module) do
    {:ok, fsm_pid} = FSM.start_link(module)
    Module.put_attribute(module, :_bond_fsm_pid, fsm_pid)
  end

  @doc false
  defmacro __before_compile__(%Macro.Env{} = env) do
    FSM.stop(fsm(env))
    Module.delete_attribute(env.module, :_bond_fsm_pid)
  end

  def register_assertion(:pre, expression, label, env, meta) do
    register_assertion(:precondition, expression, label, env, meta)
  end

  def register_assertion(:post, expression, label, env, meta) do
    register_assertion(:postcondition, expression, label, env, meta)
  end

  def register_assertion(kind, expression, label, env, meta) do
    assertion = Assertion.new(kind, label, expression, env, meta)

    fsm_event =
      case kind do
        :precondition -> :precondition_def
        :postcondition -> :postcondition_def
      end

    apply(FSM, fsm_event, [fsm(env), assertion])
  end

  def check_assertion(expression, label, env, meta) do
    check = Bond.Assertion.new(:check, label, expression, env, meta)
    Bond.Assertion.quoted_eval(check)
  end

  def define_function_with_contract(env, definition, body, public?) do
    fsm = fsm(env)
    FSM.function_def(fsm, definition)
    preconditions = FSM.pending_preconditions(fsm)
    postconditions = FSM.pending_postconditions(fsm)
    body_with_contracts = wrap_function_body(body, preconditions, postconditions)

    precondition_docs =
      preconditions
      |> Enum.map(&to_string/1)
      |> Enum.join("\n")

    if public? do
      quote do
        # case Module.get_attribute(__MODULE__, :doc) do
        #   {line, doc} ->
        #     Module.put_attribute(
        #       __MODULE__,
        #       :doc,
        #       {line, doc <> "\n\n## Preconditions\n\n#{unquote(precondition_docs)}"}
        #     )
        #
        #   nil ->
        #     Module.put_attribute(
        #       __MODULE__,
        #       :doc,
        #       {0, "\n\n## Preconditions\n\n#{unquote(precondition_docs)}"}
        #     )
        # end
        #
        # IO.inspect(Module.get_attribute(__MODULE__, :doc))

        @doc preconditions: unquote(precondition_docs)
        Kernel.def(unquote(definition), unquote(body_with_contracts))
      end
    else
      quote do
        Kernel.defp(unquote(definition), unquote(body_with_contracts))
      end
    end
  end

  defp wrap_function_body(body, preconditions, postconditions) do
    preconditions_ast = Enum.map(preconditions, &Assertion.quoted_eval/1)

    {postconditions, old_context} = OldExpression.precompile(postconditions)
    old_resolved_ast = OldExpression.resolve(old_context)
    postconditions_ast = Enum.map(postconditions, &Assertion.quoted_eval(&1))

    Keyword.update!(body, :do, fn do_block ->
      quote do
        unquote_splicing(preconditions_ast)
        unquote_splicing(old_resolved_ast)

        var!(result) = unquote(do_block)
        unquote_splicing(postconditions_ast)
        var!(result)
      end
    end)
  end

  defp fsm(%Macro.Env{module: module}), do: Module.get_attribute(module, :_bond_fsm_pid)
end
