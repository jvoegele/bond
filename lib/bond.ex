defmodule Bond do
  # Pull in the moduledocs from the demarcated section of the README file
  @readme Path.expand("./README.md")
  @external_resource @readme
  @moduledoc @readme
             |> File.read!()
             |> String.split("<!-- README START -->")
             |> Enum.at(1)
             |> String.split("<!-- README END -->")
             |> List.first()

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

  # This clause handles either "bare" @pre or @post assertions that do not have a label
  # attached to them, or keyword lists where the keys are labels and the values are the
  # assertions.
  defmacro @{pre_or_post, meta, [expression]} when pre_or_post in [:pre, :post] do
    if Keyword.keyword?(expression) do
      for {label, expression} <- expression do
        Bond.Contracts.register_assertion(pre_or_post, expression, label, __CALLER__, meta)
      end
    else
      Bond.Contracts.register_assertion(pre_or_post, expression, nil, __CALLER__, meta)
    end

    :ok
  end

  # This clause handles @pre or @post assertions that have a label preceding them.
  defmacro @{pre_or_post, meta, [label, {_, _, _} = expression]}
           when (pre_or_post in [:pre, :post] and is_atom(label)) or is_binary(label) do
    Bond.Contracts.register_assertion(pre_or_post, expression, label, __CALLER__, meta)
    :ok
  end

  # This clause handles @pre or @post assertions that have a label following them.
  defmacro @{pre_or_post, meta, [{_, _, _} = expression, label]}
           when (pre_or_post in [:pre, :post] and is_atom(label)) or is_binary(label) do
    Bond.Contracts.register_assertion(pre_or_post, expression, label, __CALLER__, meta)
    :ok
  end

  defmacro @{:doc, meta, [value]} do
    Bond.Contracts.register_doc(__CALLER__, meta, value)
    :ok
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
