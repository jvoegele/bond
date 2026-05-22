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
end
