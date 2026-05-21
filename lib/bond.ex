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

  @doc false
  defmacro __using__(_opts) do
    Bond.Compiler.init(__CALLER__.module)

    quote do
      # Read the `:bond` application config in the *user's* module body so
      # `Application.compile_env/3` works (it cannot be called inside a macro/function body,
      # only in a module body) and so the compile-env dependency is correctly tracked for
      # recompilation. `Bond.Compiler.__before_compile__/1` reads this attribute back to
      # decide which contracts to emit.
      @__bond_contract_config__ %{
        preconditions: Application.compile_env(:bond, :preconditions, true),
        postconditions: Application.compile_env(:bond, :postconditions, true),
        checks: Application.compile_env(:bond, :checks, true)
      }

      import Kernel, except: [@: 1]
      import Bond

      @on_definition Bond.Compiler
      @before_compile Bond.Compiler
      @after_compile Bond.Compiler
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
        Bond.Compiler.register_assertion(pre_or_post, expression, label, __CALLER__, meta)
      end
    else
      Bond.Compiler.register_assertion(pre_or_post, expression, nil, __CALLER__, meta)
    end

    :ok
  end

  # This clause handles @pre or @post assertions that have a label preceding them.
  defmacro @{pre_or_post, meta, [label, {_, _, _} = expression]}
           when (pre_or_post in [:pre, :post] and is_atom(label)) or is_binary(label) do
    Bond.Compiler.register_assertion(pre_or_post, expression, label, __CALLER__, meta)
    :ok
  end

  # This clause handles @pre or @post assertions that have a label following them.
  defmacro @{pre_or_post, meta, [{_, _, _} = expression, label]}
           when (pre_or_post in [:pre, :post] and is_atom(label)) or is_binary(label) do
    Bond.Compiler.register_assertion(pre_or_post, expression, label, __CALLER__, meta)
    :ok
  end

  defmacro @{:doc, meta, [value]} do
    Bond.Compiler.register_doc(__CALLER__, meta, value)
    :ok
  end

  defmacro @attr do
    # Forward any other module attributes that are not `@pre` or `@post` to `Kernel.@/1`
    quote do
      Kernel.@(unquote(attr))
    end
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

  > #### Conditional compilation {: .info}
  >
  > `check` honours the `:bond, :checks` application config. When set to `false`, every `check`
  > call in modules that `use Bond` expands to `:ok` and the wrapped expression is **not
  > evaluated** at all. Don't rely on side effects inside `check` expressions, and don't rely
  > on the return value of `check` if your build may have checks disabled.
  """
  @spec check(assertion_expression()) :: as_boolean(any())
  @spec check(Keyword.t(assertion_expression())) :: list(as_boolean(any()))
  defmacro check(assertion_or_list_of_assertions)

  defmacro check(keyword_list) when is_list(keyword_list) do
    if checks_enabled?(__CALLER__.module) do
      for {label, {_, meta, _} = expression} <- keyword_list do
        Bond.Compiler.check_assertion(expression, label, __CALLER__, meta)
      end
    else
      :ok
    end
  end

  defmacro check({_, meta, _} = expression) do
    if checks_enabled?(__CALLER__.module) do
      Bond.Compiler.check_assertion(expression, nil, __CALLER__, meta)
    else
      :ok
    end
  end

  @doc """
  Check a single labelled assertion for validity.

  See `check/1` for details and examples.
  """
  defmacro check(label_or_expression, expression_or_label)

  @spec check(assertion_label(), assertion_expression()) :: as_boolean(any())
  defmacro check(label, {_, meta, _} = expression) when is_atom(label) or is_binary(label) do
    if checks_enabled?(__CALLER__.module) do
      Bond.Compiler.check_assertion(expression, label, __CALLER__, meta)
    else
      :ok
    end
  end

  @spec check(assertion_expression(), assertion_label()) :: as_boolean(any())
  defmacro check({_, meta, _} = expression, label) when is_atom(label) or is_binary(label) do
    if checks_enabled?(__CALLER__.module) do
      Bond.Compiler.check_assertion(expression, label, __CALLER__, meta)
    else
      :ok
    end
  end

  # Read the per-module `:checks` config previously stashed by `__using__`. Modules that did not
  # `use Bond` have no attribute set; in that case we default to enabled (a defensive choice —
  # such a `check` call would otherwise be a no-op for surprising reasons).
  defp checks_enabled?(module) do
    case Module.get_attribute(module, :__bond_contract_config__) do
      %{checks: false} -> false
      _ -> true
    end
  end
end
