defmodule Bond.PropertyTest.ServerSequence do
  @moduledoc internal: true

  @moduledoc """
  Sequence generator and runners behind `Bond.PropertyTest.server_invariants_hold/2` (#54) — the
  process-world sibling of `Bond.PropertyTest.Sequence` (which targets struct modules).

  A `Bond.Server` weaves its `@state_invariant`/`@transition_invariant` (and each callback's
  `@pre`/`@post`) into the compiled callbacks, so driving the server through a random sequence of
  messages lets those contracts be the *oracle* over the reachable state space — no model needed.
  Two execution strategies share one generator:

    * `:callbacks` — seed state from `init/1` and invoke `handle_call`/`handle_cast`/`handle_info`
      directly, threading the returned state into the next call via
      `Bond.Runtime.Server.extract_state/2`. Deterministic and in-process: a contract violation
      raises straight out and the surrounding `check all` shrinks the sequence. It follows a
      genuinely reachable trajectory (real `init`, real callback returns), but does not exercise
      real dispatch, mailbox ordering, or timers.
    * `:process` — start a real (unlinked) server and drive it with `GenServer.call`/`cast`/`send`,
      using `:sys.get_state/1` as a barrier between steps and recovering an in-server crash from a
      monitor. See `run_process/3`.

  The message generator (`generator/2`) produces a `StreamData` list of `{category, message}`
  ops; `StreamData`'s `list_of` shrinker minimises the failing sequence for free.
  """

  @type category :: :call | :cast | :info
  @typedoc "One message op: a category and the term sent/handled."
  @type op :: {category(), term()}
  @typedoc "`{fun_name, [arg_generators]}` — a message shape and generators for its arguments."
  @type message_spec :: {atom(), [StreamData.t(term())]}

  @default_max_length 20

  @doc """
  Returns a `StreamData` generator of message-op lists (`[{category, message}]`) from the
  `messages:` specs — a keyword list of `call:`/`cast:`/`info:`, each a list of `t:message_spec/0`.

  A message with no argument generators becomes the bare atom `name`; with arguments it becomes
  `{name, arg1, …}` — the idiomatic GenServer request/message shapes. `:max_length` (default
  #{@default_max_length}) caps the sequence length.
  """
  @spec generator(keyword(), keyword()) :: StreamData.t([op()])
  def generator(message_specs, opts \\ []) do
    max_length = Keyword.get(opts, :max_length, @default_max_length)

    op_gens =
      for {category, specs} <- message_specs,
          {name, arg_gens} <- specs do
        StreamData.bind(StreamData.fixed_list(arg_gens), fn args ->
          StreamData.constant({category, build_message(name, args)})
        end)
      end

    case op_gens do
      [] ->
        raise ArgumentError,
              "server_invariants_hold requires a non-empty `:messages` keyword " <>
                "(e.g. `messages: [call: [{:deposit, [gen]}], info: [{:tick, []}]]`)."

      gens ->
        StreamData.list_of(StreamData.one_of(gens), max_length: max_length)
    end
  end

  # No-arg messages are bare atoms (`:tick`); argument-bearing messages are tuples
  # (`{:deposit, 10}`), matching the shapes servers pattern-match in their callbacks.
  defp build_message(name, []), do: name
  defp build_message(name, args), do: List.to_tuple([name | args])

  @doc """
  Runs one generated sequence in **callback mode**: seed the state from `module.init(init_arg)`,
  then invoke the state-transition callbacks in order, threading each returned state into the next.

  Bond's woven invariant checks are the oracle — a `Bond.InvariantError` (or any callback
  `@pre`/`@post` failure) raises out of here and fails the surrounding property. A `:no_state`
  return (`{:stop, …}`, `:ignore`) ends the sequence cleanly, as does `init` declining to start.
  """
  @spec run_callbacks(module(), term(), [op()]) :: :ok
  def run_callbacks(module, init_arg, ops) do
    case Bond.Runtime.Server.extract_state(:init, module.init(init_arg)) do
      :no_state -> :ok
      {:state, state} -> thread_callbacks(module, state, ops)
    end
  end

  defp thread_callbacks(_module, _state, []), do: :ok

  defp thread_callbacks(module, state, [{category, message} | rest]) do
    return = invoke_callback(module, category, message, state)

    case Bond.Runtime.Server.extract_state(callback_name(category), return) do
      :no_state -> :ok
      {:state, new_state} -> thread_callbacks(module, new_state, rest)
    end
  end

  # Direct callback invocation. Because `Bond.Server` weaves the contract checks into the public
  # callback, these calls fire the `@state_invariant` on the returned state and the
  # `@transition_invariant` relating `state` (old) to the returned state (new).
  defp invoke_callback(module, :call, message, state),
    do: module.handle_call(message, {self(), make_ref()}, state)

  defp invoke_callback(module, :cast, message, state),
    do: module.handle_cast(message, state)

  defp invoke_callback(module, :info, message, state),
    do: module.handle_info(message, state)

  defp callback_name(:call), do: :handle_call
  defp callback_name(:cast), do: :handle_cast
  defp callback_name(:info), do: :handle_info

  @doc """
  Runs one generated sequence in **process mode**: start a fresh, *unlinked* server with
  `init_arg`, drive it through the message sequence with real `GenServer.call`/`cast` and `send/2`,
  and let its woven invariant checks be the oracle.

  A fresh server per call keeps shrink-replay deterministic. `:sys.get_state/1` after each message
  is a synchronisation barrier — it forces the server to process any asynchronous cast/info before
  the next step, so a violation is attributed to the message that caused it. When the server
  crashes, the reason is recovered from the monitor: a `Bond.InvariantError` (or callback
  `@pre`/`@post` failure) is re-raised so the surrounding property fails and shrinks; a clean stop
  (`:normal`/`:shutdown`) ends the sequence; any other crash is surfaced as a failure naming the
  reason.
  """
  @spec run_process(module(), term(), [op()]) :: :ok
  def run_process(module, init_arg, ops) do
    case GenServer.start(module, init_arg) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        try do
          drive_process(pid, ref, ops)
        after
          stop_server(pid, ref)
        end

      # init/1 raised a contract violation while building the initial state.
      {:error, {%Bond.InvariantError{} = error, _stacktrace}} ->
        raise error

      # init/1 declined for a non-contract reason (`{:stop, _}`) or `:ignore` — nothing to drive.
      {:error, _reason} ->
        :ok

      :ignore ->
        :ok
    end
  end

  defp drive_process(_pid, _ref, []), do: :ok

  defp drive_process(pid, ref, [{category, message} | rest]) do
    case dispatch_and_sync(category, pid, ref, message) do
      :ok -> drive_process(pid, ref, rest)
      :stopped -> :ok
      {:violation, error} -> raise error
      {:crash, reason} -> raise "Bond server property: driven server crashed: #{inspect(reason)}"
    end
  end

  # Send the message, then synchronise. `:sys.get_state/1` blocks until the server has processed
  # its mailbox up to this point (draining an async cast/info), and exits if the server has died —
  # at which point the monitor's `:DOWN` carries the crash reason.
  defp dispatch_and_sync(category, pid, ref, message) do
    dispatch(category, pid, message)
    :sys.get_state(pid)
    :ok
  catch
    :exit, _reason -> classify_down(ref, pid)
  end

  defp dispatch(:call, pid, message), do: GenServer.call(pid, message)
  defp dispatch(:cast, pid, message), do: GenServer.cast(pid, message)
  defp dispatch(:info, pid, message), do: send(pid, message)

  defp classify_down(ref, pid) do
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> classify_reason(reason)
    after
      100 -> {:crash, :unknown}
    end
  end

  defp classify_reason({%Bond.InvariantError{} = error, _stacktrace}), do: {:violation, error}
  defp classify_reason(reason) when reason in [:normal, :shutdown], do: :stopped
  defp classify_reason({:shutdown, _reason}), do: :stopped
  defp classify_reason(reason), do: {:crash, reason}

  defp stop_server(pid, ref) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal)
      catch
        :exit, _reason -> :ok
      end
    end

    Process.demonitor(ref, [:flush])
  end
end
