defmodule Bond.ServerConfigTest do
  @moduledoc false

  # async: false — toggles the process-global :persistent_term runtime-modes entry via Bond.Config.
  use ExUnit.Case, async: false

  defmodule Ledger do
    use GenServer
    use Bond.Server

    @state_invariant non_negative: state.balance >= 0

    @impl true
    def init(balance), do: {:ok, %{balance: balance}}

    @impl true
    def handle_cast({:set, balance}, s), do: {:noreply, %{s | balance: balance}}
  end

  setup do
    on_exit(&Bond.Config.reset/0)
    :ok
  end

  test "state invariants are enforced by default" do
    Process.flag(:trap_exit, true)
    assert {:error, {%Bond.StateInvariantError{}, _}} = GenServer.start_link(Ledger, -1)
  end

  test "Bond.Config.disable(:invariants) skips state-invariant checks at runtime" do
    Bond.Config.disable(:invariants)

    {:ok, pid} = GenServer.start_link(Ledger, -5)
    assert :sys.get_state(pid) == %{balance: -5}

    # A subsequent violating transition is also skipped while disabled.
    GenServer.cast(pid, {:set, -10})
    assert :sys.get_state(pid) == %{balance: -10}

    GenServer.stop(pid)
  end

  test "re-enabling restores enforcement" do
    Bond.Config.disable(:invariants)
    Bond.Config.enable(:invariants)
    Process.flag(:trap_exit, true)

    assert {:error, {%Bond.StateInvariantError{}, _}} = GenServer.start_link(Ledger, -1)
  end
end
