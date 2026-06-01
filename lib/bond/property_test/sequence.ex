defmodule Bond.PropertyTest.Sequence do
  @moduledoc internal: true
  @moduledoc """
  Sequence generator and runner used by `Bond.PropertyTest.invariants_hold/2`
  (the stateful module-sequence shape).

  A *sequence* is a tuple `{constructor_op, [step_op, ...]}` where:

    * `constructor_op` — `{:constructor, fun_name, args}`. Called once to produce the
      initial state. The arity is `length(args)`.
    * `step_op` — `{:transformer, fun_name, args}` or `{:observer, fun_name, args}`.

  Transformers receive the current state as their *first* argument with the user-supplied
  args after it (so a `transformer: [{:push, [term_gen]}]` spec means `push/2` is called
  as `push(state, term)`). Observers behave the same way but don't advance state.

  Supported transformer return shapes:

    * `%StructModule{}` — becomes the new state.
    * `{:ok, %StructModule{}}` — same; the wrapper is stripped.
    * `{:error, _}` — terminates the sequence cleanly. The property *passes* in this case;
      it's normal Elixir for an operation to be refused, and the type system doesn't
      consider that a contract violation.

  Anything else from a transformer raises an `ArgumentError` with a message pointing at
  the offending fn — the caller's spec is wrong.

  Constructors must return either a bare struct or `{:ok, struct}`. `{:error, _}` from a
  constructor halts the sequence before any steps run.

  Bond's own runtime instrumentation (`@invariant`, `@pre`, `@post`) is the *oracle* — any
  contract violation raises out through `run/2` and the surrounding `check all` catches
  it as a property failure with shrinking.
  """

  @type op_spec :: {atom(), [StreamData.t(any())]}
  @type module_name :: module()

  @doc """
  Returns a `StreamData` generator that produces sequences of operations over the given
  module's struct.

  `constructors` must be non-empty. `transformers` and `observers` may be empty
  (independently); if both are empty, the sequence is just a constructor call with no
  follow-up steps. Maximum sequence length defaults to 20 step ops to keep test runs
  bounded.
  """
  @spec generator([op_spec()], [op_spec()], [op_spec()], keyword()) :: StreamData.t(term())
  def generator(constructors, transformers, observers, opts \\ []) do
    if constructors == [] do
      raise ArgumentError, "Bond.PropertyTest: `constructors:` must be non-empty"
    end

    max_length = Keyword.get(opts, :max_length, 20)

    ctor_gen = StreamData.one_of(build_op_gens(:constructor, constructors))

    step_gens =
      build_op_gens(:transformer, transformers) ++
        build_op_gens(:observer, observers)

    steps_gen =
      case step_gens do
        [] -> StreamData.constant([])
        gens -> StreamData.list_of(StreamData.one_of(gens), max_length: max_length)
      end

    StreamData.tuple({ctor_gen, steps_gen})
  end

  # Build a generator per (fn_name, arg_gens) spec, each producing a tagged op tuple.
  defp build_op_gens(kind, specs) when kind in [:constructor, :transformer, :observer] do
    Enum.map(specs, fn {fun_name, arg_gens} when is_atom(fun_name) and is_list(arg_gens) ->
      StreamData.bind(StreamData.fixed_list(arg_gens), fn args ->
        StreamData.constant({kind, fun_name, args})
      end)
    end)
  end

  @doc """
  Runs a generated sequence against `module`, threading state through transformers.

  Returns `:ok` if the sequence completes normally (including terminating via an
  `{:error, _}` return). Raises whatever Bond's runtime instrumentation raises if a
  contract violation occurs — the surrounding `check all` catches that as the property
  failure.
  """
  @spec run(module_name(), term()) :: :ok
  def run(module, {{:constructor, fun_name, args}, steps}) do
    case apply(module, fun_name, args) do
      {:error, _} ->
        :ok

      result ->
        state = unwrap_struct!(result, module, fun_name, args)
        run_steps(module, state, steps)
    end
  end

  defp run_steps(_module, _state, []), do: :ok

  defp run_steps(module, state, [{:observer, fun_name, args} | rest]) do
    # Observers don't advance state. The call fires the pre-invariant on entry; the
    # return value is discarded.
    apply(module, fun_name, [state | args])
    run_steps(module, state, rest)
  end

  defp run_steps(module, state, [{:transformer, fun_name, args} | rest]) do
    case apply(module, fun_name, [state | args]) do
      {:error, _} ->
        # Operation declined. Sequence ends cleanly; remaining ops are skipped. Not a
        # contract failure.
        :ok

      result ->
        new_state = unwrap_struct!(result, module, fun_name, [state | args])
        run_steps(module, new_state, rest)
    end
  end

  defp unwrap_struct!(%_{} = struct, _module, _fun, _args), do: struct

  defp unwrap_struct!({:ok, %_{} = struct}, _module, _fun, _args), do: struct

  defp unwrap_struct!(other, module, fun, args) do
    raise ArgumentError,
          "Bond.PropertyTest: #{inspect(module)}.#{fun}/#{length(args)} returned " <>
            "an unsupported shape: #{inspect(other)}. Form 2 supports bare struct or " <>
            "`{:ok, struct}` returns. `{:error, _}` terminates the sequence cleanly. " <>
            "Wrap your function if it returns anything else, or test it with Form 1."
  end
end
