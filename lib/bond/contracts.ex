defmodule Bond.Contracts do
  @moduledoc internal: true
  @moduledoc """
  Internal helper module for defining contracts for a module at compile-time.
  """

  alias Bond.Assertion
  alias Bond.CompileStateFSM, as: FSM
  alias Bond.FunctionWithContract

  def init(module) do
    {:ok, fsm_pid} = FSM.start_link(module)
    Module.put_attribute(module, :_bond_fsm_pid, fsm_pid)
  end

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

  def register_doc(env, meta, value) do
    FSM.doc_attribute(fsm(env), {meta, value})
  end

  def check_assertion(expression, label, env, meta) do
    check = Bond.Assertion.new(:check, label, expression, env, meta)
    Bond.Assertion.quoted_eval(check)
  end

  def define_function_with_contract(env, definition, body, public?) do
    fsm = fsm(env)
    function = FunctionWithContract.new(env, definition, body)
    FSM.function_def(fsm, definition)

    preconditions = FSM.pending_preconditions(fsm)
    postconditions = FSM.pending_postconditions(fsm)

    docs = append_contract_docs(FSM.pending_doc_attributes(fsm), preconditions, postconditions)

    function = FunctionWithContract.apply_contract(function, preconditions, postconditions)
    body_with_contracts = function.body_ast

    result =
      if public? do
        quote do
          Enum.each(unquote(docs), fn {meta, doc} ->
            Module.put_attribute(__MODULE__, :doc, {meta[:line], doc})
          end)

          Kernel.def(unquote(definition), unquote(body_with_contracts))
        end
      else
        quote do
          Kernel.defp(unquote(definition), unquote(body_with_contracts))
        end
      end

    FSM.doc_attributes_applied(fsm)
    result
  end

  defp append_contract_docs([], _preconditions, _postconditions), do: []

  defp append_contract_docs(function_docs, preconditions, postconditions) do
    precondition_docs = generate_docs(preconditions, header: "#### Preconditions")
    postcondition_docs = generate_docs(postconditions, header: "#### Postconditions")

    contract_docs =
      case {Enum.empty?(precondition_docs), Enum.empty?(postcondition_docs)} do
        {true, true} -> []
        {true, false} -> postcondition_docs
        {false, true} -> precondition_docs
        {false, false} -> [precondition_docs, "\n\n", postcondition_docs]
      end

    Enum.map(function_docs, fn
      {meta, doc} when is_binary(doc) ->
        doc_iodata = [doc, contract_docs]
        {meta, IO.iodata_to_binary(doc_iodata)}

      {meta, keyword} when is_list(keyword) ->
        {meta, keyword}
    end)
  end

  defp generate_docs([], _), do: []

  defp generate_docs(assertions, opts) do
    header = if header = opts[:header], do: header <> "\n\n", else: ""

    assertions
    |> Enum.reduce([], fn
      %{label: nil, code: code}, acc ->
        [code | acc]

      assertion, acc ->
        label = assertion.label |> inspect() |> String.trim_leading(":")
        [[label, ": ", assertion.code] | acc]
    end)
    |> Enum.reverse()
    |> List.insert_at(0, header)
    |> Enum.intersperse("\n    ")
  end

  defp fsm(%Macro.Env{module: module}), do: Module.get_attribute(module, :_bond_fsm_pid)
end
