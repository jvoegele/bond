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

  ## Assertion syntax

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

  @typedoc false
  @type assertion_kind :: :precondition | :postcondition | :check

  @typedoc """
  Type to represent a label for an assertion, which must be a compile-time atom or string.
  """
  @type assertion_label :: String.t() | atom()

  @typedoc """
  Type to represent a compile-time quoted assertion expression, which must be a valid Elixir
  expression that, when unquoted, evaluates to a `t:boolean/0` or `t:as_boolean/1` value.
  """
  @type assertion_expression :: {atom(), Macro.metadata(), list()}

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
    Bond.Contracts.init(__CALLER__.module)

    quote do
      import Kernel, except: [@: 1, def: 2, defp: 2]
      import Bond

      @before_compile Bond.Contracts
    end
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
        Bond.Contracts.register_assertion(pre_or_post, expression, label, __CALLER__, meta)
      end
    else
      Bond.Contracts.register_assertion(pre_or_post, expression, nil, __CALLER__, meta)
    end
  end

  defmacro @{pre_or_post, meta, [label, {_, _, _} = expression]}
           when (pre_or_post in [:pre, :post] and is_atom(label)) or is_binary(label) do
    # This clause handles @pre or @post assertions that have a label preceding them.
    Bond.Contracts.register_assertion(pre_or_post, expression, label, __CALLER__, meta)
  end

  defmacro @{pre_or_post, meta, [{_, _, _} = expression, label]}
           when (pre_or_post in [:pre, :post] and is_atom(label)) or is_binary(label) do
    # This clause handles @pre or @post assertions that have a label following them.
    Bond.Contracts.register_assertion(pre_or_post, expression, label, __CALLER__, meta)
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
    Bond.Contracts.define_function_with_contract(__CALLER__, definition, body, true)
  end

  @doc """
  Override `Kernel.defp/2` to support wrapping with preconditions and postconditions.
  """
  defmacro defp(definition, body) do
    Bond.Contracts.define_function_with_contract(__CALLER__, definition, body, false)
  end

  @doc """
  Check an assertion or a keyword list of assertions for validity.

  Returns the result(s) of the assertion(s) if satisfied, or raises a `Bond.CheckError` exception
  if any assertions are not satisfied.

  ## Examples

      iex> check 1 == 1.0
      true
      iex> check 1 == 1.0, "integer 1 is equal to float 1.0"
      true
      iex> check "integer 1 is equal to float 1.0", 1 == 1.0
      true
      iex> check tautology: 1 == 1
      [true]
      iex> check "1 is 1": 1 == 1, "2 is 2": 2 == 2
      [true, true]
  """
  @spec check(assertion_expression()) :: as_boolean(any())
  @spec check(Keyword.t(assertion_expression())) :: list(as_boolean(any()))
  defmacro check(assertion_or_list_of_assertions)

  defmacro check(keyword_list) when is_list(keyword_list) do
    for {label, {_, meta, _} = expression} <- keyword_list do
      Bond.Contracts.check_assertion(expression, label, __CALLER__, meta)
    end
  end

  defmacro check({_, meta, _} = expression) do
    Bond.Contracts.check_assertion(expression, nil, __CALLER__, meta)
  end

  @doc """
  Check a single labelled assertion for validity.

  See `check/1` for details and examples.
  """
  defmacro check(label_or_expression, expression_or_label)

  @spec check(assertion_label(), assertion_expression()) :: as_boolean(any())
  defmacro check(label, {_, meta, _} = expression) when is_atom(label) or is_binary(label) do
    Bond.Contracts.check_assertion(expression, label, __CALLER__, meta)
  end

  @spec check(assertion_expression(), assertion_label()) :: as_boolean(any())
  defmacro check({_, meta, _} = expression, label) when is_atom(label) or is_binary(label) do
    Bond.Contracts.check_assertion(expression, label, __CALLER__, meta)
  end
end
