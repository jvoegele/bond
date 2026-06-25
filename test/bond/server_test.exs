defmodule Bond.ServerTest do
  use ExUnit.Case, async: true

  defmodule Counter do
    use GenServer
    use Bond.Server

    @state_invariant non_negative: state.count >= 0

    @impl true
    def init(n), do: {:ok, %{count: n}}

    @impl true
    def handle_call(:inc, _from, %{count: c} = s), do: {:reply, c + 1, %{s | count: c + 1}}
    # Deliberately defines NO handle_cast/handle_info/handle_continue/code_change — GenServer
    # provides defaults for some of those, which must NOT be captured.
  end

  defmodule MultiInvariant do
    use GenServer
    use Bond.Server

    # Bare (unlabelled), keyword, and multi-entry keyword forms, across two declarations.
    @state_invariant state.count >= 0
    @state_invariant capped: state.count <= state.max, has_max: is_integer(state.max)

    @impl true
    def init(max), do: {:ok, %{count: 0, max: max}}

    @impl true
    def handle_cast(:inc, s), do: {:noreply, %{s | count: s.count + 1}}
  end

  defmodule FullServer do
    use GenServer
    use Bond.Server

    @impl true
    def init(s), do: {:ok, s}
    @impl true
    def handle_call(_m, _f, s), do: {:reply, :ok, s}
    @impl true
    def handle_cast(_m, s), do: {:noreply, s}
    @impl true
    def handle_info(_m, s), do: {:noreply, s}
    @impl true
    def handle_continue(_c, s), do: {:noreply, s}
    @impl true
    def code_change(_old, s, _extra), do: {:ok, s}
  end

  describe "__bond_server_callbacks__/0" do
    test "records exactly the user-defined GenServer callbacks, in canonical order" do
      assert Counter.__bond_server_callbacks__() == [init: 1, handle_call: 3]
    end

    test "records every defined transition callback, in canonical order" do
      assert FullServer.__bond_server_callbacks__() == [
               init: 1,
               handle_call: 3,
               handle_cast: 2,
               handle_info: 2,
               handle_continue: 2,
               code_change: 3
             ]
    end

    test "does not capture GenServer-injected default callbacks" do
      callbacks = Counter.__bond_server_callbacks__()
      refute {:handle_cast, 2} in callbacks
      refute {:handle_info, 2} in callbacks
      refute {:code_change, 3} in callbacks
    end

    test "captures a user callback even though it overrides a GenServer default" do
      # handle_call/3 fires @on_definition with overridable?=true (it overrides GenServer's
      # default); Bond.Server must still record it — the spike's critical finding.
      assert {:handle_call, 3} in Counter.__bond_server_callbacks__()
    end
  end

  describe "__bond_state_invariants__/0" do
    test "captures a labelled state invariant as {label, code}" do
      assert Counter.__bond_state_invariants__() == [{:non_negative, "state.count >= 0"}]
    end

    test "captures bare and multi-entry keyword forms, in declaration order" do
      assert MultiInvariant.__bond_state_invariants__() == [
               {nil, "state.count >= 0"},
               {:capped, "state.count <= state.max"},
               {:has_max, "is_integer(state.max)"}
             ]
    end

    test "is empty when no state invariants are declared" do
      assert FullServer.__bond_state_invariants__() == []
    end
  end

  test "the skeleton leaves GenServer behaviour intact" do
    {:ok, pid} = GenServer.start_link(Counter, 0)
    assert GenServer.call(pid, :inc) == 1
    assert GenServer.call(pid, :inc) == 2
    GenServer.stop(pid)
  end
end
