defmodule Bond.PropertyTest do
  @moduledoc """
  Property-based testing helpers that drive Bond-contracted functions with random inputs.

  Bond contracts (`@pre`, `@post`, `check/1,2`, `@invariant`) are runtime predicates that
  already encode what "correct" looks like. Property-based testing usually has two hard
  parts — generating inputs, and writing the oracle that distinguishes right from wrong
  outputs. With Bond, the oracle is *already there at every call site*; PBT just feeds
  random inputs in and lets the existing instrumentation raise on any violation.

  `Bond.PropertyTest` adds a single macro, `contract_holds/2`, with two forms:

    * **Single function.** Pass a function reference and a list of generators (one per
      argument). The macro calls the function with random inputs; any contract violation
      fails the property and StreamData shrinks to a minimal counterexample.

          contract_holds &Math.sqrt/1, args: [StreamData.float(min: 0.0)]

    * **Module sequence.** Pass a struct module plus constructor / transformer / observer
      specs. The macro generates random sequences of operations over the struct and runs
      them; the module's `@invariant`s (plus any per-function contracts) are the oracle.

          contract_holds BoundedStack,
            constructors: [{:new, [StreamData.integer(1..100)]}],
            transformers: [{:push, [StreamData.term()]}, {:pop, []}],
            observers:    [{:size, []}, {:peek, []}]

  ## Setup

  `Bond.PropertyTest` depends on
  [`stream_data`](https://hex.pm/packages/stream_data). It's listed as an optional
  dependency in `bond`'s mix file, so users opting into PBT add it to their own deps:

      {:stream_data, "~> 0.6", only: [:dev, :test]}

  Then in a test file:

      defmodule MyTest do
        use ExUnit.Case
        use Bond.PropertyTest

        # contract_holds ...
      end

  If `stream_data` is not available at compile time, `use Bond.PropertyTest` raises a
  `CompileError` with instructions to add the dep.
  """

  @missing_stream_data_msg """
  Bond.PropertyTest requires the :stream_data dependency, but it is not available.

  Add it to your project's mix.exs:

      defp deps do
        [
          {:stream_data, "~> 0.6", only: [:dev, :test]},
          # ...
        ]
      end

  Then run `mix deps.get`.
  """

  @doc """
  When `use`d in an ExUnit test module, brings in `ExUnitProperties` (for the underlying
  `property/2` and `check all` macros) and imports `Bond.PropertyTest` so `contract_holds`
  is available.

  Raises a `CompileError` at the `use` site if `stream_data` isn't available — see the
  module docs.
  """
  defmacro __using__(_opts) do
    unless Code.ensure_loaded?(StreamData) do
      raise CompileError, description: unquote(@missing_stream_data_msg)
    end

    quote do
      use ExUnitProperties
      import Bond.PropertyTest
    end
  end

  @doc """
  Generates an ExUnit property that calls the given function with random arguments and
  verifies that Bond's contracts (preconditions, postconditions, `check`s, invariants)
  are all satisfied.

  Two forms are supported, dispatched by the first argument:

  ## Single function (Form 1)

  Pass a function reference and a list of generators, one per argument:

      contract_holds &Math.sqrt/1, args: [StreamData.float(min: 0.0)]

  The macro expands to a `property` block. On each iteration it generates one value per
  argument and calls the function. Any contract violation raised by Bond's runtime
  instrumentation fails the property; StreamData then shrinks to the minimal
  counterexample.

  Useful for catching edge cases your example-based tests didn't cover. The function's
  contracts are the oracle — no separate assertion is needed.

  ## Module sequence (Form 2)

  *Not yet implemented — arrives in a subsequent commit.* Pass a struct module plus
  constructor / transformer / observer specs; the macro generates random sequences of
  operations and runs them, with the module's `@invariant`s as the oracle.

  ## Options for Form 1

    * `:args` (required) — a list of `StreamData` generators, one per function argument.
      The function is called via `apply/2` with the generated values.

    * `:name` (optional) — a string used as the property's description. Defaults to
      `"contract_holds <function-ref-source>"`.
  """
  defmacro contract_holds(fun_or_module, opts)

  defmacro contract_holds({:&, _, _} = fun_ast, opts) do
    contract_holds_for_function(fun_ast, opts)
  end

  defp contract_holds_for_function(fun_ast, opts) do
    args_gens =
      Keyword.get(opts, :args) ||
        raise ArgumentError,
              "contract_holds for a single function requires an `:args` keyword " <>
                "with a list of generators (one per function argument)"

    name = Keyword.get(opts, :name, "contract_holds #{Macro.to_string(fun_ast)}")

    quote do
      property unquote(name) do
        check all args <- StreamData.fixed_list(unquote(args_gens)) do
          apply(unquote(fun_ast), args)
        end
      end
    end
  end
end
