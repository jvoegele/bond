defmodule Bond.PropertyTest do
  @moduledoc """
  Property-based testing helpers that drive Bond-contracted functions with random inputs.

  Bond contracts (`@pre`, `@post`, `check/1,2`, `@invariant`) are runtime predicates that
  already encode what "correct" looks like. Property-based testing usually has two hard
  parts — generating inputs, and writing the oracle that distinguishes right from wrong
  outputs. With Bond, the oracle is *already there at every call site*; PBT just feeds
  random inputs in and lets the existing instrumentation raise on any violation.

  `Bond.PropertyTest` adds four macros, one per testing shape:

    * **`contract_holds/2` — single function.** Pass a function reference and a list of
      generators (one per argument). The macro calls the function with random inputs; any
      contract violation fails the property and StreamData shrinks to a minimal
      counterexample.

          contract_holds &Math.sqrt/1, args: [StreamData.float(min: 0.0)]

    * **`probe_contract/2` — single function, boundary-driven.** Like `contract_holds/2`, but it
      mixes the boundary values implied by the function's `@pre` into your generators — both value
      edges (`@pre x >= 0`) and size edges (`@pre length(items) <= 3`, building collections of the
      boundary size) — and *filters* out inputs that violate `@pre` (rather than failing on them),
      so the function's `@post` is the oracle and its precondition edges are probed deliberately.

          probe_contract &Account.withdraw/2, args: [account_gen(), StreamData.integer()]

    * **`invariants_hold/2` — stateful module sequence.** Pass a struct module plus
      constructor / transformer / observer specs. The macro generates random sequences of
      operations over the struct and runs them; the module's `@invariant`s (plus any
      per-function contracts) are the oracle across every reachable state.

          invariants_hold BoundedStack,
            constructors: [{:new, [StreamData.integer(1..100)]}],
            transformers: [{:push, [StreamData.term()]}, {:pop, []}],
            observers:    [{:size, []}, {:peek, []}]

    * **`server_invariants_hold/2` — stateful `Bond.Server` message sequence.** The
      process-world sibling of `invariants_hold/2`: drive a server through random
      `call`/`cast`/`info` sequences and let its `@state_invariant`/`@transition_invariant`
      be the oracle across the reachable state space.

          server_invariants_hold Bank,
            init: StreamData.integer(0..100),
            messages: [call: [{:withdraw, [StreamData.positive_integer()]}],
                       cast: [{:deposit, [StreamData.positive_integer()]}]]

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
      moved to invariants_hold/2 in Bond 1.0.

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
      are hit regularly rather than by chance. Two kinds of edge are probed:
        * **Value boundaries** from `arg <op> literal` (e.g. `0` and its neighbours for
          `@pre x >= 0`) are injected as values.
        * **Size boundaries** from `length(arg) <op> literal` (and `byte_size`, `tuple_size`,
          `map_size`) cause Bond to *construct* collections/binaries of the boundary sizes from
          your generator's output — truncating or padding (by cycling elements) toward the target
          size — so `@pre length(items) <= 3` is probed with length-2/3/4 lists. A map can only be
          shrunk toward a smaller target (new keys can't be synthesised safely); an undersized one
          is left for the `@pre` filter to discard.
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
    * **Boundaries come only from `@pre` literal comparisons** — not from constants in the
      function body. A behaviourally significant value buried in the implementation (e.g. the `5`
      in `Enum.split(items, 5)`, or a threshold the body branches on) is invisible to
      `probe_contract`, because Bond reads boundaries from the *precondition*, not the body. If a
      body constant marks an interesting edge, generate around it yourself (e.g. lists whose length
      straddles it), or lift it into a `@pre` if it is genuinely part of the contract.
    * If a single-clause function destructures an argument in its head (e.g.
      `def f(%Account{} = a, n)`), your generator for that argument must produce shape-matching
      values, exactly as the function itself requires.
    * If the precondition is so restrictive that too many generated inputs are discarded,
      `probe_contract/2` raises `Bond.PropertyTest.FilterTooRestrictiveError`, which names the
      function and suggests narrowing your base generators (or using `StreamData.bind/2` for
      relational preconditions like `amount <= account.balance`, which boundary injection can't
      probe for you).

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
        fun = unquote(fun)
        arity = unquote(arity)
        boundaries = Bond.PropertyTest.__boundaries__(mod, fun, arity)
        gens = Bond.PropertyTest.__augment_generators__(unquote(args_gens), boundaries)

        try do
          check all args <- StreamData.fixed_list(gens),
                    Bond.PropertyTest.__satisfies_pre__(mod, fun, arity, args) do
            apply(unquote(fun_ast), args)
          end
        rescue
          error in StreamData.FilterTooNarrowError ->
            Bond.PropertyTest.__reraise_too_restrictive__(error, mod, fun, arity, __STACKTRACE__)
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
  # Translates StreamData's generic "too many filtered" error into a Bond-shaped one that names the
  # function whose precondition did the filtering and suggests narrowing the generators (#43). The
  # original stacktrace is preserved so the failure still points at the user's `probe_contract` call.
  def __reraise_too_restrictive__(error, mod, fun, arity, stacktrace) do
    reraise Bond.PropertyTest.FilterTooRestrictiveError,
            [
              module: mod,
              function: fun,
              arity: arity,
              last_generated_value: error.last_generated_value
            ],
            stacktrace
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
  # Blends boundary probes into each argument's base generator. An argument with probes is drawn
  # from its base generator ~75% of the time and a boundary draw ~25% of the time, so the edges are
  # probed regularly while the base generator still drives broad coverage. Arguments with no probes
  # keep their generator untouched.
  #
  # A probe is either a bare number — a *value* boundary, injected directly via `member_of` — or a
  # `{:size, wrapper, n}` tuple — a *size* boundary, where a value drawn from the base generator is
  # resized to `n` (see `__resize__/3`). Value probes and size probes for the same argument are
  # offered with equal weight inside the boundary draw.
  def __augment_generators__(arg_gens, boundaries)
      when is_list(arg_gens) and is_map(boundaries) do
    arg_gens
    |> Enum.with_index()
    |> Enum.map(fn {gen, index} -> augment_one(gen, Map.get(boundaries, index)) end)
  end

  # Blends one argument's boundary probes into its base generator, or returns the base generator
  # untouched when the argument has no probes (or none that could build a generator).
  defp augment_one(base_gen, probes) when is_list(probes) and probes != [] do
    case boundary_choices(base_gen, probes) do
      [] -> base_gen
      choices -> StreamData.frequency([{3, base_gen}, {1, StreamData.one_of(choices)}])
    end
  end

  defp augment_one(base_gen, _none), do: base_gen

  # Builds the list of boundary generators for one argument from its probe list: at most one
  # `member_of` generator for all the value probes, plus one resizing generator per size wrapper.
  defp boundary_choices(base_gen, probes) do
    {values, sizes} = Enum.split_with(probes, &is_number/1)

    value_choice = if values == [], do: [], else: [StreamData.member_of(values)]

    size_choices =
      sizes
      |> Enum.group_by(fn {:size, wrapper, _n} -> wrapper end, fn {:size, _w, n} -> n end)
      |> Enum.map(fn {wrapper, ns} ->
        targets = ns |> Enum.uniq() |> Enum.sort()

        StreamData.bind(base_gen, fn value ->
          StreamData.member_of(Enum.map(targets, &__resize__(wrapper, value, &1)))
        end)
      end)

    value_choice ++ size_choices
  end

  @doc false
  # Resizes a value drawn from the base generator to a target size `n` for a size boundary, reusing
  # the value's own elements/bytes so they still satisfy any element-level precondition:
  #
  #   * too large → truncate to the first `n`;
  #   * too small → pad by cycling the existing elements/bytes;
  #   * empty and `n > 0` → left unchanged (nothing to cycle), so the `@pre` filter discards it as a
  #     generation miss rather than fabricating elements that might violate the contract;
  #   * a map that needs to *grow* → left unchanged (new unique keys can't be synthesised safely);
  #   * a type the wrapper doesn't match (the base generator produced something unexpected) → left
  #     unchanged, to be caught by the `@pre` filter.
  #
  # Leaving a value unchanged is always safe: the precondition is still the oracle, so a value that
  # can't be coerced to the boundary is simply filtered out rather than probed.
  def __resize__(:length, value, n) when is_list(value), do: resize_list(value, n)
  def __resize__(:byte_size, value, n) when is_binary(value), do: resize_binary(value, n)

  def __resize__(:tuple_size, value, n) when is_tuple(value) do
    value |> Tuple.to_list() |> resize_list(n) |> List.to_tuple()
  end

  def __resize__(:map_size, value, n) when is_map(value) and not is_struct(value) do
    resize_map(value, n)
  end

  def __resize__(_wrapper, value, _n), do: value

  defp resize_list(list, n) do
    len = length(list)

    cond do
      len == n -> list
      len > n -> Enum.take(list, n)
      list == [] -> list
      true -> list |> Stream.cycle() |> Enum.take(n)
    end
  end

  defp resize_binary(binary, n) do
    size = byte_size(binary)

    cond do
      size == n -> binary
      size > n -> binary_part(binary, 0, n)
      size == 0 -> binary
      true -> binary |> :binary.copy(div(n, size) + 1) |> binary_part(0, n)
    end
  end

  # Maps can only be shrunk: padding would require fabricating new unique keys, which risks
  # violating the contract, so an undersized map is left as-is and filtered by `@pre`.
  defp resize_map(map, n) do
    if map_size(map) >= n do
      map |> Enum.take(n) |> Map.new()
    else
      map
    end
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

  @doc """
  Generates an ExUnit property that drives a `Bond.Server` through random sequences of messages
  and verifies its `@state_invariant`/`@transition_invariant` (plus each callback's `@pre`/`@post`)
  hold across the reachable state space.

  This is the process-world sibling of `invariants_hold/2`: for a server, the invariants are an
  even more compelling free oracle, since the reachable state space is otherwise tedious to
  enumerate by hand. Pass the server module, an `:init` generator, and `:messages` specs:

      server_invariants_hold Bank,
        init: StreamData.integer(0..100),
        messages: [
          call: [{:withdraw, [StreamData.positive_integer()]}, {:balance, []}],
          cast: [{:deposit, [StreamData.positive_integer()]}],
          info: [{:tick, []}]
        ]

  Each iteration generates an initial argument and a random message sequence, drives the server
  through it, and lets any contract violation fail the property; `StreamData` shrinks to a minimal
  `(init, sequence)` counterexample. A message spec `{name, [arg_generators]}` becomes the bare
  atom `name` when it has no arguments (`{:tick, []}` → `:tick`) or the tuple `{name, …}` otherwise
  (`{:withdraw, [gen]}` → `{:withdraw, amount}`).

  ## Execution modes

    * `:callbacks` (the default) — seeds state from `init/1` and invokes the callbacks directly,
      threading each returned state into the next. Deterministic and fast; follows a genuinely
      reachable trajectory (real `init`, real callback returns) but does not exercise real
      dispatch, mailbox ordering, or timers.
    * `:process` — starts a real (unlinked) server per sequence and drives it with
      `GenServer.call`/`cast` and `send/2`, using `:sys.get_state/1` as a barrier so asynchronous
      casts/infos are processed before the next step. Highest fidelity (real dispatch, mailbox
      ordering, timers); a contract violation crashes the server and is recovered from the monitor
      and re-raised as a shrinkable property failure.

  ## Options

    * `:init` (required) — a `StreamData` generator for the argument passed to the server's
      `init/1` (and `start_link/1` in `:process` mode).
    * `:messages` (required, non-empty) — keyword list of `call:`/`cast:`/`info:`, each a list of
      `{fun_name, [arg_generators]}` message specs.
    * `:mode` (optional, default `:callbacks`) — `:callbacks` or `:process`.
    * `:max_length` (optional, default 20) — maximum message-sequence length.
    * `:name` (optional) — the property description. Defaults to `"server_invariants_hold <module>"`.
  """
  defmacro server_invariants_hold(module, opts)

  defmacro server_invariants_hold({:__aliases__, _, _} = module_ast, opts) do
    init_gen = Keyword.get(opts, :init)
    messages = Keyword.get(opts, :messages, [])
    mode = Keyword.get(opts, :mode, :callbacks)
    max_length = Keyword.get(opts, :max_length, 20)
    name = Keyword.get(opts, :name, "server_invariants_hold #{Macro.to_string(module_ast)}")

    if init_gen == nil do
      raise ArgumentError,
            "server_invariants_hold requires an `:init` generator (the argument passed to the " <>
              "server's init/1), e.g. `init: StreamData.integer(0..100)`."
    end

    if messages == [] do
      raise ArgumentError,
            "server_invariants_hold requires a non-empty `:messages` keyword " <>
              "(e.g. `messages: [call: [{:deposit, [gen]}], info: [{:tick, []}]]`)."
    end

    run_op =
      case mode do
        :callbacks ->
          quote do:
                  Bond.PropertyTest.ServerSequence.run_callbacks(
                    unquote(module_ast),
                    init_arg,
                    ops
                  )

        :process ->
          quote do:
                  Bond.PropertyTest.ServerSequence.run_process(unquote(module_ast), init_arg, ops)

        other ->
          raise ArgumentError,
                "server_invariants_hold :mode must be :callbacks or :process, got: #{inspect(other)}"
      end

    quote do
      property unquote(name) do
        sequence_gen =
          Bond.PropertyTest.ServerSequence.generator(unquote(messages),
            max_length: unquote(max_length)
          )

        check all(
                init_arg <- unquote(init_gen),
                ops <- sequence_gen
              ) do
          unquote(run_op)
        end
      end
    end
  end

  defmacro server_invariants_hold(other, _opts) do
    raise ArgumentError,
          "server_invariants_hold expects a Bond.Server module as its first argument, got: " <>
            Macro.to_string(other)
  end
end
