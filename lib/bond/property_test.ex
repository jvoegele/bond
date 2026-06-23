defmodule Bond.PropertyTest do
  @moduledoc """
  Property-based testing helpers that drive Bond-contracted functions with random inputs.

  Bond contracts (`@pre`, `@post`, `check/1,2`, `@invariant`) are runtime predicates that
  already encode what "correct" looks like. Property-based testing usually has two hard
  parts — generating inputs, and writing the oracle that distinguishes right from wrong
  outputs. With Bond, the oracle is *already there at every call site*; PBT just feeds
  random inputs in and lets the existing instrumentation raise on any violation.

  `Bond.PropertyTest` adds three macros, one per testing shape:

    * **`contract_holds/2` — single function.** Pass a function reference and a list of
      generators (one per argument). The macro calls the function with random inputs; any
      contract violation fails the property and StreamData shrinks to a minimal
      counterexample.

          contract_holds &Math.sqrt/1, args: [StreamData.float(min: 0.0)]

    * **`probe_contract/2` — single function, boundary-driven.** Like `contract_holds/2`, but it
      mixes the boundary values implied by the function's `@pre` into your generators and *filters*
      out inputs that violate `@pre` (rather than failing on them), so the function's `@post` is the
      oracle and its precondition edges are probed deliberately.

          probe_contract &Account.withdraw/2, args: [account_gen(), StreamData.integer()]

    * **`invariants_hold/2` — stateful module sequence.** Pass a struct module plus
      constructor / transformer / observer specs. The macro generates random sequences of
      operations over the struct and runs them; the module's `@invariant`s (plus any
      per-function contracts) are the oracle across every reachable state.

          invariants_hold BoundedStack,
            constructors: [{:new, [StreamData.integer(1..100)]}],
            transformers: [{:push, [StreamData.term()]}, {:pop, []}],
            observers:    [{:size, []}, {:peek, []}]

  ## Setup

  `Bond.PropertyTest` depends on
  [`stream_data`](https://hex.pm/packages/stream_data). It's listed as an optional
  dependency in `bond`'s mix file, so users opting into PBT add it to their own deps:

      {:stream_data, "~> 1.0", only: [:dev, :test]}

  Then in a test file:

      defmodule MyTest do
        use ExUnit.Case
        use Bond.PropertyTest

        # contract_holds ... / invariants_hold ...
      end

  If `stream_data` is not available at compile time, `use Bond.PropertyTest` raises a
  `CompileError` with instructions to add the dep.
  """

  @missing_stream_data_msg """
  Bond.PropertyTest requires the :stream_data dependency, but it is not available.

  Add it to your project's mix.exs:

      defp deps do
        [
          {:stream_data, "~> 1.0", only: [:dev, :test]},
          # ...
        ]
      end

  Then run `mix deps.get`.
  """

  @doc """
  When `use`d in an ExUnit test module, brings in `ExUnitProperties` (for the underlying
  `property/2` and `check all` macros) and imports `Bond.PropertyTest` so `contract_holds`
  and `invariants_hold` are available.

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
  Generates an ExUnit property that calls a single function with random arguments and
  verifies that Bond's contracts (preconditions, postconditions, `check`s, invariants)
  are all satisfied.

  Pass a function reference and a list of generators, one per argument:

      contract_holds &Math.sqrt/1, args: [StreamData.float(min: 0.0)]

  The macro expands to a `property` block. On each iteration it generates one value per
  argument and calls the function. Any contract violation raised by Bond's runtime
  instrumentation fails the property; StreamData then shrinks to the minimal
  counterexample.

  Useful for catching edge cases your example-based tests didn't cover. The function's
  contracts are the oracle — no separate assertion is needed.

  For stateful testing over a struct module — random sequences of operations checked
  against the module's `@invariant`s — see `invariants_hold/2`.

  ## Options

    * `:args` (required) — list of `StreamData` generators, one per function argument.
    * `:name` (optional) — a string used as the property's description. Defaults to
      `"contract_holds <source>"`.
  """
  defmacro contract_holds(fun, opts)

  defmacro contract_holds({:&, _, _} = fun_ast, opts) do
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

  # Clean break (1.0.0-rc.3): the module-sequence form moved to `invariants_hold/2`.
  defmacro contract_holds({:__aliases__, _, _} = module_ast, _opts) do
    mod = Macro.to_string(module_ast)

    raise CompileError,
      description: """
      contract_holds/2 no longer accepts a module — the stateful module-sequence form \
      moved to invariants_hold/2 in Bond 1.0.0-rc.3.

      Replace:

          contract_holds #{mod}, constructors: [...], transformers: [...], observers: [...]

      with:

          invariants_hold #{mod}, constructors: [...], transformers: [...], observers: [...]
      """
  end

  @doc """
  Generates an ExUnit property that *probes a function at its precondition boundaries*: it mixes
  the boundary values implied by the function's `@pre` (e.g. `0` and its neighbours for
  `@pre x >= 0`) into your generators, discards any generated input that does not satisfy `@pre`,
  and lets the function's own `@post`/`check` contracts be the oracle on the inputs that survive.

  Pass a remote function capture and one base generator per argument:

      probe_contract &Account.withdraw/2, args: [account_generator(), StreamData.integer()]

  How it differs from `contract_holds/2`:

    * **Boundary probing.** Bond reads the function's `__bond_boundaries__/0` reflection (emitted
      from the literal comparisons in its `@pre`) and blends each argument's boundary candidates
      into that argument's generator, so the edges — where off-by-one postcondition bugs live —
      are hit regularly rather than by chance.
    * **`@pre` as a filter, not a guard.** A generated input that violates the precondition is
      *discarded* — a generation miss, not a failure — instead of raising. `contract_holds/2`, by
      contrast, calls the function unconditionally and lets a `@pre` violation fail the property.
      Reach for `probe_contract/2` to generate broadly and probe boundaries; for `contract_holds/2`
      when your generators already produce only valid inputs.

  Because preconditions are the filter, the `@post` and `check` contracts are the oracle: any
  postcondition violation on a *valid* input fails the property and StreamData shrinks to a minimal
  counterexample.

  ## Requirements and notes

    * The capture must be a **remote** function (`&Module.fun/arity`) — the contracts and the
      `__bond_boundaries__/0` / `__bond_precondition__/3` reflections live on that module.
    * Functions whose `@pre` has no literal comparison (or no `@pre` at all) are still exercised:
      there are simply no boundary candidates to inject and nothing to filter, so `probe_contract`
      degrades gracefully to plain generated testing.
    * If a single-clause function destructures an argument in its head (e.g.
      `def f(%Account{} = a, n)`), your generator for that argument must produce shape-matching
      values, exactly as the function itself requires.
    * If the precondition is so restrictive that too many generated inputs are discarded,
      StreamData raises its standard "too many filtered" error — narrow your base generators (or
      use `StreamData.bind/2` for relational preconditions) so they produce valid inputs more often.

  ## Options

    * `:args` (required) — list of `StreamData` generators, one per function argument.
    * `:name` (optional) — the property's description. Defaults to `"probe_contract <source>"`.
  """
  defmacro probe_contract(fun, opts)

  defmacro probe_contract(
             {:&, _, [{:/, _, [{{:., _, [mod_ast, fun]}, _, []}, arity]}]} = fun_ast,
             opts
           )
           when is_atom(fun) and is_integer(arity) do
    args_gens =
      Keyword.get(opts, :args) ||
        raise ArgumentError,
              "probe_contract requires an `:args` keyword with a list of generators " <>
                "(one per function argument)"

    name = Keyword.get(opts, :name, "probe_contract #{Macro.to_string(fun_ast)}")

    quote do
      property unquote(name) do
        mod = unquote(mod_ast)
        boundaries = Bond.PropertyTest.__boundaries__(mod, unquote(fun), unquote(arity))
        gens = Bond.PropertyTest.__augment_generators__(unquote(args_gens), boundaries)

        check all args <- StreamData.fixed_list(gens),
                  Bond.PropertyTest.__satisfies_pre__(mod, unquote(fun), unquote(arity), args) do
          apply(unquote(fun_ast), args)
        end
      end
    end
  end

  defmacro probe_contract(other, _opts) do
    raise ArgumentError,
          "probe_contract expects a remote function capture like `&Module.fun/arity`, got: " <>
            Macro.to_string(other)
  end

  @doc false
  # Returns the boundary-candidate map (`%{arg_index => [values]}`) for `{fun, arity}`, or `%{}`
  # when the module emitted no boundaries reflection (no literal-comparison precondition anywhere).
  def __boundaries__(mod, fun, arity) do
    if function_exported?(mod, :__bond_boundaries__, 0) do
      Map.get(mod.__bond_boundaries__(), {fun, arity}, %{})
    else
      %{}
    end
  end

  @doc false
  # The generation filter: true when `args` satisfies the function's `@pre`. Routes through the
  # non-raising `__bond_precondition__/3` shim; a module with no compiled precondition exports no
  # shim, in which case there is nothing to filter and every input passes.
  def __satisfies_pre__(mod, fun, arity, args) do
    if function_exported?(mod, :__bond_precondition__, 3) do
      mod.__bond_precondition__(fun, arity, args)
    else
      true
    end
  end

  @doc false
  # Blends boundary candidates into each argument's base generator. An argument with candidates is
  # drawn from its base generator ~75% of the time and a boundary value ~25% of the time, so the
  # edges are probed regularly while the base generator still drives broad coverage. Arguments with
  # no candidates keep their generator untouched.
  def __augment_generators__(arg_gens, boundaries)
      when is_list(arg_gens) and is_map(boundaries) do
    arg_gens
    |> Enum.with_index()
    |> Enum.map(fn {gen, index} ->
      case Map.get(boundaries, index) do
        candidates when is_list(candidates) and candidates != [] ->
          StreamData.frequency([{3, gen}, {1, StreamData.member_of(candidates)}])

        _none ->
          gen
      end
    end)
  end

  @doc """
  Generates an ExUnit property that runs random sequences of operations over a struct
  module and verifies that the module's `@invariant`s (plus any per-function contracts)
  hold across every reachable state.

  This is Bond's stateful, sequence-based property testing. The invariants are a *free
  oracle* — they hold at every entry and exit, so there's no need to write an explicit
  per-operation model of expected behaviour, which is what makes stateful PBT cheap here.

  Pass a struct module plus *constructor*, *transformer*, and *observer* specs. The macro
  generates random sequences of operations over the struct, threads state through them,
  and runs them.

      invariants_hold BoundedStack,
        constructors: [{:new, [StreamData.integer(1..100)]}],
        transformers: [{:push, [StreamData.term()]}, {:pop, []}],
        observers:    [{:size, []}, {:peek, []}]

  Each spec is a list of `{fun_name, [arg_generators]}` tuples:

    * **Constructor** — produces an initial struct. Called first in every sequence.
    * **Transformer** — takes the current struct as its first argument plus generated
      args, returns a new struct (`%Mod{}` or `{:ok, %Mod{}}`). Advances the state.
    * **Observer** — takes the current struct plus generated args, returns anything.
      Doesn't advance state. The pre-invariant still fires on entry.

  Return shape rules for constructors and transformers:

    * `%Mod{}` — becomes the new state.
    * `{:ok, %Mod{}}` — same; the wrapper is stripped.
    * `{:error, _}` — terminates the sequence cleanly (the property *passes*; an operation
      that refuses is not a contract violation).
    * Anything else raises an `ArgumentError`; wrap your function or test it with
      `contract_holds/2`.

  > #### The oracle is invariants *and* per-function contracts {: .info}
  >
  > The runner also checks each operation's own `@pre`/`@post`/`check` contracts as it
  > goes, so a struct module with per-function contracts but no `@invariant` is still
  > meaningfully exercised. Invariants are the headline because they're what make the
  > sequence form pull its weight — a module with no invariants buys little over testing
  > each function with `contract_holds/2`.

  ## Options

    * `:constructors` (required, non-empty) — list of `{fun_name, [arg_generators]}`.
    * `:transformers` (optional, default `[]`) — same shape; state threaded in as the
      first argument.
    * `:observers` (optional, default `[]`) — same shape; state passed but not advanced.
    * `:name` (optional) — a string used as the property's description. Defaults to
      `"invariants_hold <module>"`.
  """
  defmacro invariants_hold(module, opts)

  defmacro invariants_hold({:__aliases__, _, _} = module_ast, opts) do
    constructors = Keyword.get(opts, :constructors, [])
    transformers = Keyword.get(opts, :transformers, [])
    observers = Keyword.get(opts, :observers, [])

    if constructors == [] do
      raise ArgumentError,
            "invariants_hold requires a non-empty `:constructors` keyword " <>
              "(a list of {fun_name, [arg_generators]} tuples). " <>
              "Constructors are how the sequence starts — there's no way to test " <>
              "invariants on a struct module without a way to produce instances."
    end

    name = Keyword.get(opts, :name, "invariants_hold #{Macro.to_string(module_ast)}")

    quote do
      property unquote(name) do
        sequence_gen =
          Bond.PropertyTest.Sequence.generator(
            unquote(constructors),
            unquote(transformers),
            unquote(observers)
          )

        check all sequence <- sequence_gen do
          Bond.PropertyTest.Sequence.run(unquote(module_ast), sequence)
        end
      end
    end
  end
end
