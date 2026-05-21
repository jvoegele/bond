defmodule Bond.Compiler do
  @moduledoc internal: true
  @moduledoc """
  Internal helper module for defining contracts for a module at compile-time.

  Bond installs this module as the `@on_definition`, `@before_compile`, and `@after_compile`
  handler for any module that does `use Bond`. As the user's module is being compiled:

    * `@pre`, `@post`, and `@doc` annotations are intercepted by `Bond` and forwarded here via
      `register_assertion/5` and `register_doc/3`. They accumulate in the per-module
      `Bond.Compiler.CompileStateFSM` process.
    * Every `def` and `defp` definition fires `__on_definition__/6`, which builds a
      `Bond.Compiler.FunctionDefinition` and feeds it to the FSM. The FSM groups clauses by
      `{module, fun, arity}` and attaches any pending preconditions/postconditions/docs to the
      resulting `Bond.Compiler.AnnotatedFunction`.
    * `__before_compile__/1` asks the FSM for every `AnnotatedFunction` that has a contract and
      delegates to `AnnotatedFunction.apply_contract/1` to emit a `defoverridable` plus a
      single override clause that wraps the original function in pre/post evaluation.
    * `__after_compile__/2` stops the FSM process.
  """

  alias Bond.Compiler.AnnotatedFunction
  alias Bond.Compiler.Assertion
  alias Bond.Compiler.CompileStateFSM, as: FSM
  alias Bond.Compiler.FunctionDefinition

  # Functions Elixir auto-generates as a side effect of constructs like `defstruct` and
  # `defexception`. These show up via `@on_definition` and must not be tracked as user
  # contract candidates.
  @generated_functions ~w[__struct__ __exception__ __info__]a

  @doc false
  def init(module) do
    {:ok, _fsm_pid} = FSM.start_link(module)
    :ok
  end

  @doc false
  def __on_definition__(_env, kind, _fun, _params, _guards, _body)
      when kind in [:defmacro, :defmacrop] do
    # Bond does not (yet) support contracts on macros.
    :ok
  end

  def __on_definition__(_env, _kind, fun, _params, _guards, _body)
      when fun in @generated_functions do
    :ok
  end

  # Bodyless function heads (`def foo(x)` with no `do` block) are used purely to attach
  # docs/specs/contracts to the clauses that follow. They don't produce executable code, so we
  # skip them — the contracts will be picked up by the first body-bearing clause.
  def __on_definition__(_env, kind, _fun, _params, _guards, nil) when kind in [:def, :defp] do
    :ok
  end

  def __on_definition__(env, kind, fun, params, guards, body) when kind in [:def, :defp] do
    function_def = FunctionDefinition.new(env, kind, fun, params, guards, body)
    FSM.function_def(fsm(env), function_def)
  end

  @doc false
  defmacro __before_compile__(%Macro.Env{} = env) do
    :ok = FSM.module_defined(fsm(env))

    config =
      Module.get_attribute(env.module, :__bond_contract_config__) ||
        %{preconditions: true, postconditions: true}

    fsm(env)
    |> FSM.annotated_functions()
    |> Enum.filter(&AnnotatedFunction.override?/1)
    |> Enum.map(&AnnotatedFunction.apply_contract(&1, config))
    |> Enum.reject(&is_nil/1)
  end

  @doc false
  def __after_compile__(env, _bytecode) do
    FSM.stop(fsm(env))
  end

  @doc false
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

  @doc false
  def register_doc(env, meta, value) do
    FSM.doc_attribute(fsm(env), {meta, value})
  end

  @doc false
  def check_assertion(expression, label, env, meta) do
    check = Assertion.new(:check, label, expression, env, meta)
    Assertion.quoted_eval(check)
  end

  @spec fsm(Macro.Env.t()) :: FSM.server_ref()
  defp fsm(%Macro.Env{module: module}), do: FSM.server_ref(module)
end
