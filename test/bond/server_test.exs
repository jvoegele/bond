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

  describe "__bond_state_invariant_check__/1 (lifted check)" do
    test "returns :ok when every state invariant holds" do
      assert Counter.__bond_state_invariant_check__(%{count: 0}) == :ok
      assert Counter.__bond_state_invariant_check__(%{count: 7}) == :ok
      assert MultiInvariant.__bond_state_invariant_check__(%{count: 0, max: 10}) == :ok
    end

    test "throws an :assertion_failure when an invariant is violated" do
      assert {:assertion_failure, %{kind: :state_invariant, label: :non_negative}} =
               catch_throw(Counter.__bond_state_invariant_check__(%{count: -1}))
    end

    test "via evaluate_state_invariants/2, raises StateInvariantError attributed to the callback" do
      error =
        assert_raise Bond.StateInvariantError, fn ->
          Bond.Runtime.Eval.evaluate_state_invariants(
            fn -> Counter.__bond_state_invariant_check__(%{count: -1}) end,
            {:handle_call, 3}
          )
        end

      message = Exception.message(error)
      assert message =~ "state invariant violated after Bond.ServerTest.Counter.handle_call/3"
      assert message =~ "label: :non_negative"
      assert message =~ "assertion: state.count >= 0"
    end

    test "checks multiple invariants and reports the first violated one" do
      assert {:assertion_failure, %{label: :capped}} =
               catch_throw(MultiInvariant.__bond_state_invariant_check__(%{count: 11, max: 10}))
    end

    test "is not emitted for a module with no state invariants" do
      refute function_exported?(FullServer, :__bond_state_invariant_check__, 1)
    end
  end

  test "the skeleton leaves GenServer behaviour intact" do
    {:ok, pid} = GenServer.start_link(Counter, 0)
    assert GenServer.call(pid, :inc) == 1
    assert GenServer.call(pid, :inc) == 2
    GenServer.stop(pid)
  end

  describe "runtime enforcement around callbacks (S5)" do
    defmodule Bank do
      use GenServer
      use Bond.Server

      @state_invariant non_negative_balance: state.balance >= 0

      @impl true
      def init(balance), do: {:ok, %{balance: balance}}

      @impl true
      def handle_call({:withdraw, amount}, _from, %{balance: b} = s),
        do: {:reply, :ok, %{s | balance: b - amount}}

      @impl true
      def handle_cast({:deposit, amount}, %{balance: b} = s),
        do: {:noreply, %{s | balance: b + amount}}

      @impl true
      # Inline mutation that violates the invariant — the exact case a struct @invariant misses.
      def handle_info(:corrupt, s), do: {:noreply, %{s | balance: -1}}
    end

    test "a satisfying transition passes through normally" do
      {:ok, pid} = GenServer.start_link(Bank, 100)
      assert GenServer.call(pid, {:withdraw, 40}) == :ok
      assert :sys.get_state(pid) == %{balance: 60}
      GenServer.stop(pid)
    end

    test "init/1 establishes the invariant (creation check)" do
      Process.flag(:trap_exit, true)

      assert {:error, {%Bond.StateInvariantError{} = err, _stack}} =
               GenServer.start_link(Bank, -5)

      assert Exception.message(err) =~ "state invariant violated after"
      assert Exception.message(err) =~ "init/1"
    end

    test "handle_call violation raises StateInvariantError attributed to the callback" do
      {:ok, pid} = GenServer.start_link(Bank, 100)
      Process.flag(:trap_exit, true)
      Process.link(pid)

      # A crash mid-call exits the caller with {server_reason, call_info}, where
      # server_reason is {exception, stacktrace}.
      {{err, _stacktrace}, _call_info} = catch_exit(GenServer.call(pid, {:withdraw, 250}))

      assert %Bond.StateInvariantError{
               label: :non_negative_balance,
               function: {:handle_call, 3},
               binding: [state: %{balance: -150}]
             } = err
    end

    test "handle_info inline-mutation violation is caught (the struct-@invariant blind spot)" do
      {:ok, pid} = GenServer.start_link(Bank, 100)
      Process.flag(:trap_exit, true)
      Process.link(pid)

      send(pid, :corrupt)
      assert_receive {:EXIT, ^pid, {%Bond.StateInvariantError{function: {:handle_info, 2}}, _}}
    end
  end

  # A server defining every state-transition callback, each able to set the state directly, so the
  # wrapper for each can be exercised by direct invocation (the wrapper is the public def, so
  # calling it runs super + the state-invariant check synchronously — no live process needed).
  defmodule Probe do
    use GenServer
    use Bond.Server

    @state_invariant non_negative: state.n >= 0

    @impl true
    def init(n), do: {:ok, %{n: n}}
    @impl true
    def handle_call({:set, n}, _from, s), do: {:reply, :ok, %{s | n: n}}
    @impl true
    def handle_cast({:set, n}, s), do: {:noreply, %{s | n: n}}
    @impl true
    def handle_info({:set, n}, s), do: {:noreply, %{s | n: n}}
    @impl true
    def handle_continue({:set, n}, s), do: {:noreply, %{s | n: n}}
    @impl true
    def code_change(_old_vsn, s, {:set, n}), do: {:ok, %{s | n: n}}
  end

  describe "every state-transition callback is wrapped (S6)" do
    test "valid transitions pass through unchanged" do
      assert Probe.init(0) == {:ok, %{n: 0}}
      assert Probe.handle_call({:set, 5}, :from, %{n: 0}) == {:reply, :ok, %{n: 5}}
      assert Probe.handle_cast({:set, 5}, %{n: 0}) == {:noreply, %{n: 5}}
      assert Probe.handle_info({:set, 5}, %{n: 0}) == {:noreply, %{n: 5}}
      assert Probe.handle_continue({:set, 5}, %{n: 0}) == {:noreply, %{n: 5}}
      assert Probe.code_change(:v0, %{n: 0}, {:set, 5}) == {:ok, %{n: 5}}
    end

    test "a violating result raises StateInvariantError attributed to that callback" do
      for {invoke, fa} <- [
            {fn -> Probe.init(-1) end, {:init, 1}},
            {fn -> Probe.handle_call({:set, -1}, :from, %{n: 0}) end, {:handle_call, 3}},
            {fn -> Probe.handle_cast({:set, -1}, %{n: 0}) end, {:handle_cast, 2}},
            {fn -> Probe.handle_info({:set, -1}, %{n: 0}) end, {:handle_info, 2}},
            {fn -> Probe.handle_continue({:set, -1}, %{n: 0}) end, {:handle_continue, 2}},
            {fn -> Probe.code_change(:v0, %{n: 0}, {:set, -1}) end, {:code_change, 3}}
          ] do
        error = assert_raise Bond.StateInvariantError, invoke
        assert error.function == fa
        assert error.label == :non_negative
      end
    end
  end

  defmodule Ranged do
    use GenServer
    use Bond.Server

    @state_invariant lower: state.n >= 0
    @state_invariant upper: state.n <= 100

    @impl true
    def init(n), do: {:ok, %{n: n}}
    @impl true
    def handle_cast({:set, n}, s), do: {:noreply, %{s | n: n}}
  end

  describe "multiple state invariants (S6)" do
    test "all invariants are enforced; the violated one is reported" do
      assert Ranged.handle_cast({:set, 50}, %{n: 0}) == {:noreply, %{n: 50}}

      assert_raise Bond.StateInvariantError, ~r/label: :lower/, fn ->
        Ranged.handle_cast({:set, -1}, %{n: 0})
      end

      assert_raise Bond.StateInvariantError, ~r/label: :upper/, fn ->
        Ranged.handle_cast({:set, 101}, %{n: 0})
      end
    end
  end

  defmodule Purged do
    use GenServer
    use Bond.Server, invariants: :purge

    @state_invariant non_negative: state.n >= 0

    @impl true
    def init(n), do: {:ok, %{n: n}}
    @impl true
    def handle_cast({:set, n}, s), do: {:noreply, %{s | n: n}}
  end

  describe "invariants: :purge compiles the checks out (S6)" do
    test "no check defp is emitted" do
      refute function_exported?(Purged, :__bond_state_invariant_check__, 1)
    end

    test "callbacks are not wrapped — a violating state passes through" do
      assert Purged.handle_cast({:set, -1}, %{n: 0}) == {:noreply, %{n: -1}}
      {:ok, pid} = GenServer.start_link(Purged, -5)
      assert :sys.get_state(pid) == %{n: -5}
      GenServer.stop(pid)
    end

    test "declarations are still captured for reflection" do
      assert Purged.__bond_state_invariants__() == [{:non_negative, "state.n >= 0"}]
    end
  end
end
