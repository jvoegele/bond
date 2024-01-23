defmodule Bond do
  @moduledoc """
  Design By Contract for Elixir.

  As described on [Wikipedia](https://en.wikipedia.org/wiki/Design_by_contract):

  > Design by contract (DbC), also known as contract programming, programming by contract and
  > design-by-contract programming, is an approach for designing software.
  >
  > It prescribes that software designers should define formal, precise and verifiable interface
  > specifications for software components, which extend the ordinary definition of
  > [abstract data types](https://en.wikipedia.org/wiki/Abstract_data_type) with preconditions,
  > postconditions and invariants. These specifications are referred to as "contracts", in
  > accordance with a conceptual metaphor with the conditions and obligations of business
  > contracts.
  >
  > The term was coined by [Bertrand Meyer](https://en.wikipedia.org/wiki/Bertrand_Meyer) in
  > connection with his design of the
  > [Eiffel programming language](https://en.wikipedia.org/wiki/Eiffel_(programming_language))
  > and first described in various articles starting in 1986 and the two successive editions
  > (1988, 1997) of his book
  > [_Object-Oriented Software Construction_](https://en.wikipedia.org/wiki/Object-Oriented_Software_Construction).
  >
  > Design by contract has its roots in work on
  > [formal verification](https://en.wikipedia.org/wiki/Formal_verification),
  > [formal specification](https://en.wikipedia.org/wiki/Formal_specification) and
  > [Hoare logic](https://en.wikipedia.org/wiki/Hoare_logic).

  `Bond` applies the central ideas of contract programming to Elixir and provides support for
  attaching preconditions and postconditions to function definitions and conditionally evaluating
  them based on compile-time configuration.

  ## Quick start

  `use Bond` in your module and then define preconditions and postconditions for your functions
  with the `@pre` and `@post` annotations, respectively. For example:

  ```elixir
  defmodule Math do
    use Bond

    @pre numeric_x: is_number(x), non_negative_x: x >= 0
    @post float_result: is_float(result),
          non_negative_result: result >= 0.0,
          "sqrt of 0 is 0": (x == 0) ~> (result === 0.0),
          "sqrt of 1 is 1": (x == 1) ~> (result === 1.0),
          "x > 1 implies result smaller than x": (x > 1) ~> (result < x)
    def sqrt(x), do: :math.sqrt(x)
  end
  ```

  ## Usage

  > #### `use Bond` {: .info}
  >
  > When you `use Bond`, the `Bond` module will override several `Kernel` macros in order to
  > support attaching preconditions and postconditions to functions. Specifically:
  >
  >   * `Kernel.@/1` is overridden by `Bond.@/1`
  >   * `Kernel.def/2` is overridden by `Bond.def/2`
  >   * `Kernel.defp/2` is overridden by `Bond.defp/2`
  >
  > `use Bond` will also import the `Bond` module so that the `check/1` and `check/2` macros are
  > available for use.
  >
  > Additionally, the `Bond.Predicates` module is automatically imported for all preconditions,
  > postconditions, and checks, so that the predicate functions and operators that are defined
  > therein can be used for assertions. `Bond.Predicates` can be explicitly imported into modules
  > for use outside of assertions.

  ### Assertion syntax

  Assertions in Bond are conditional Elixir expressions, optionally associated with a textual
  label (either an atom or a string). These assertions may appear in `@pre` or `@post`
  expressions, or in calls to `check/1` or `check/2`.

  Bond offers considerable flexibility in its assertion syntax; assertions may take any of the
  following forms:

    * `expression` - a "bare" expression without any associated label
    * `label, expression` - an expression preceded by a string or atom label
    * `expression, label` - an expression followed by a string or atom label
    * `label_1: expression_1, label_2: expression_2` - a keyword list with labels as the keys and
      expressions as the associated values
  """

  alias Bond.Assertion
  alias Bond.CompileStateFSM, as: FSM

  @type assertion_kind :: :precondition | :postcondition | :check
  @type assertion_label :: String.t() | atom() | nil
  @type assertion_expression :: Macro.t()

  @typedoc """
  Subset of `Macro.Env` struct that excludes fields that, according to the documentation, "are
  private to Elixir's macro expansion mechanism".
  """
  @type env :: %{
          optional(:__struct__) => module(),
          context: Macro.Env.context(),
          context_modules: Macro.Env.context_modules(),
          file: Macro.Env.file(),
          function: Macro.Env.name_arity() | nil,
          line: Macro.Env.line(),
          module: module()
        }

  @doc false
  defmacro __using__(_opts) do
    module = __CALLER__.module
    {:ok, fsm_pid} = FSM.start_link(module)
    Module.put_attribute(module, :_bond_fsm_pid, fsm_pid)

    quote do
      import Kernel, except: [@: 1, def: 2, defp: 2]
      import Bond

      @before_compile Bond
    end
  end

  @doc false
  defmacro __before_compile__(%Macro.Env{} = env) do
    FSM.stop(fsm(env))
    Module.delete_attribute(env.module, :_bond_fsm_pid)
  end

  @doc """
  Override `Kernel.@/1` to support `@pre` and `@post` annotations.

  See the `Bond` module docs for the syntax of `@pre` and `@post` annotations.
  """
  defmacro @pre_or_post

  defmacro @{pre_or_post, meta, [expression]} when pre_or_post in [:pre, :post] do
    # This clause handles "bare" @pre or @post assertions that either do not have a label
    # attached to them, or a keyword list where the keys are labels and the values are the
    # assertions.
    if Keyword.keyword?(expression) do
      for {label, expression} <- expression do
        register_assertion(pre_or_post, expression, label, __CALLER__, meta)
      end
    else
      register_assertion(pre_or_post, expression, nil, __CALLER__, meta)
    end
  end

  defmacro @{pre_or_post, meta, [label, {_, _, _} = expression]}
           when (pre_or_post in [:pre, :post] and is_atom(label)) or is_binary(label) do
    # This clause handles @pre or @post assertions that have a label preceding them.
    register_assertion(pre_or_post, expression, label, __CALLER__, meta)
  end

  defmacro @{pre_or_post, meta, [{_, _, _} = expression, label]}
           when (pre_or_post in [:pre, :post] and is_atom(label)) or is_binary(label) do
    # This clause handles @pre or @post assertions that have a label following them.
    register_assertion(pre_or_post, expression, label, __CALLER__, meta)
  end

  defmacro @attr do
    # Forward any other module attributes that are not `@pre` or `@post` to `Kernel.@/1`
    quote do
      Kernel.@(unquote(attr))
    end
  end

  @doc """
  Override `Kernel.def/2` to support wrapping with preconditions and postconditions.
  """
  defmacro def(definition, body) do
    define_function_with_contract(__CALLER__, definition, body, true)
  end

  @doc """
  Override `Kernel.defp/2` to support wrapping with preconditions and postconditions.
  """
  defmacro defp(definition, body) do
    define_function_with_contract(__CALLER__, definition, body, false)
  end

  defmacro check(expression_or_list)

  defmacro check(keyword_list) when is_list(keyword_list) do
    for {label, {_, meta, _} = expression} <- keyword_list do
      check_assertion(expression, label, __CALLER__, meta)
    end
  end

  defmacro check({_, meta, _} = expression) do
    check_assertion(expression, nil, __CALLER__, meta)
  end

  defmacro check(label_or_expression, expression_or_label)

  defmacro check(label, {_, meta, _} = expression) when is_atom(label) or is_binary(label) do
    check_assertion(expression, label, __CALLER__, meta)
  end

  defmacro check({_, meta, _} = expression, label) when is_atom(label) or is_binary(label) do
    check_assertion(expression, label, __CALLER__, meta)
  end

  defp fsm(%Macro.Env{module: module}),
    do: Module.get_attribute(module, :_bond_fsm_pid)

  defp check_assertion(expression, label, env, meta) do
    assertion = %Assertion{
      label: label,
      expression: expression,
      kind: :check,
      definition_env: Bond.Env.new(env),
      meta: meta
    }

    Bond.Assert.check!(assertion)
  end

  defp register_assertion(:pre, expression, label, env, meta) do
    register_assertion(:precondition, expression, label, env, meta)
  end

  defp register_assertion(:post, expression, label, env, meta) do
    register_assertion(:postcondition, expression, label, env, meta)
  end

  defp register_assertion(kind, expression, label, env, meta) do
    assertion = %Assertion{
      label: label,
      expression: expression,
      kind: kind,
      definition_env: Bond.Env.new(env),
      meta: meta
    }

    fsm_event =
      case kind do
        :precondition -> :precondition_def
        :postcondition -> :postcondition_def
      end

    apply(FSM, fsm_event, [fsm(env), assertion])
  end

  defp define_function_with_contract(env, definition, body, public?) do
    fsm = fsm(env)
    FSM.function_def(fsm, definition)
    preconditions = FSM.pending_preconditions(fsm)
    postconditions = FSM.pending_postconditions(fsm)
    body_with_contracts = wrap_function_body(body, preconditions, postconditions)

    if public? do
      quote do
        Kernel.def(unquote(definition), unquote(body_with_contracts))
      end
    else
      quote do
        Kernel.defp(unquote(definition), unquote(body_with_contracts))
      end
    end
  end

  defp wrap_function_body(body, preconditions, postconditions) do
    preconditions_ast = Enum.map(preconditions, &Bond.Assert.require!(&1))
    postconditions_ast = Enum.map(postconditions, &Bond.Assert.ensure!(&1))

    Keyword.update!(body, :do, fn do_block ->
      quote do
        unquote_splicing(preconditions_ast)
        var!(result) = unquote(do_block)
        unquote_splicing(postconditions_ast)
        var!(result)
      end
    end)
  end
end
