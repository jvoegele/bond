defmodule Bond.Runtime.Server do
  @moduledoc internal: true
  @moduledoc """
  Runtime support for `Bond.Server` callback wrappers (#34).

  The wrapper Bond.Server emits around each state-transition callback needs the *new* state the
  callback produced, in order to check `@state_invariant`s against it. That state is buried in
  the callback's return tuple, whose shape varies by callback and outcome. `extract_state/2`
  pattern-matches the documented `GenServer` return shapes and yields `{:state, new_state}` when
  one is present, or `:no_state` otherwise.

  Bond does not validate callback returns: a malformed return simply yields `:no_state` here and
  is left for `GenServer` itself to reject.
  """

  # The callbacks whose returns use the `:noreply` / `:stop` state-bearing shapes. `handle_call`
  # is included for those shapes; its additional `:reply` shapes are matched explicitly below.
  @noreply_callbacks [:handle_call, :handle_cast, :handle_info, :handle_continue]

  @typedoc "A GenServer state-transition callback name Bond.Server wraps."
  @type callback ::
          :init | :handle_call | :handle_cast | :handle_info | :handle_continue | :code_change

  @doc """
  Extracts the new state from a state-transition callback's return value.

  Returns `{:state, new_state}` if the return carries a new state, or `:no_state` for returns
  that do not (`init/1`'s `:ignore` / `{:stop, reason}`, `code_change/3`'s `{:error, reason}`,
  and any unrecognised/malformed return).
  """
  @spec extract_state(callback(), term()) :: {:state, term()} | :no_state

  # init/1
  def extract_state(:init, {:ok, state}), do: {:state, state}
  def extract_state(:init, {:ok, state, _extra}), do: {:state, state}

  # handle_call/3 reply shapes (plus the stop-with-reply 4-tuple). The :noreply and
  # stop-without-reply shapes are handled by the shared clauses below.
  def extract_state(:handle_call, {:reply, _reply, state}), do: {:state, state}
  def extract_state(:handle_call, {:reply, _reply, state, _extra}), do: {:state, state}
  def extract_state(:handle_call, {:stop, _reason, _reply, state}), do: {:state, state}

  # Shared :noreply / :stop shapes for handle_call/handle_cast/handle_info/handle_continue.
  def extract_state(cb, {:noreply, state}) when cb in @noreply_callbacks, do: {:state, state}

  def extract_state(cb, {:noreply, state, _extra}) when cb in @noreply_callbacks,
    do: {:state, state}

  def extract_state(cb, {:stop, _reason, state}) when cb in @noreply_callbacks,
    do: {:state, state}

  # code_change/3
  def extract_state(:code_change, {:ok, state}), do: {:state, state}

  # init :ignore / {:stop, reason}, code_change {:error, reason}, and any malformed return.
  def extract_state(_callback, _return), do: :no_state
end
