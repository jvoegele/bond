defmodule Bond.ServerPropertyTest do
  @moduledoc """
  Tests for `Bond.PropertyTest.server_invariants_hold/2` and the callback-mode runner
  (`Bond.PropertyTest.ServerSequence`, #54). The end-to-end macro is exercised by a passing
  property over a sound server; the oracle (invariants raising out of a driven sequence) and the
  transition-invariant threading are pinned deterministically by driving `run_callbacks/3` with
  hand-built sequences.
  """

  use ExUnit.Case, async: true
  use Bond.PropertyTest

  # Process-mode tests deliberately crash real servers to trigger invariant violations; capture the
  # resulting GenServer termination reports so they don't clutter the suite output.
  @moduletag :capture_log

  alias Bond.PropertyTest.ServerSequence

  defmodule SafeBank do
    @moduledoc false
    use GenServer
    use Bond.Server

    @state_invariant non_negative: state.balance >= 0

    @impl true
    def init(balance), do: {:ok, %{balance: balance}}

    @impl true
    def handle_call({:withdraw, amount}, _from, %{balance: b} = s) when amount <= b,
      do: {:reply, :ok, %{s | balance: b - amount}}

    def handle_call({:withdraw, _amount}, _from, s), do: {:reply, :insufficient, s}
    def handle_call(:balance, _from, s), do: {:reply, s.balance, s}

    @impl true
    def handle_cast({:deposit, amount}, %{balance: b} = s),
      do: {:noreply, %{s | balance: b + amount}}
  end

  defmodule LeakyBank do
    @moduledoc false
    use GenServer
    use Bond.Server

    @state_invariant non_negative: state.balance >= 0

    @impl true
    def init(balance), do: {:ok, %{balance: balance}}

    @impl true
    def handle_cast({:deposit, amount}, %{balance: b} = s),
      do: {:noreply, %{s | balance: b + amount}}

    # The bug: this corrupts the state past the invariant.
    @impl true
    def handle_info(:corrupt, s), do: {:noreply, %{s | balance: -1}}
  end

  defmodule MonotonicCounter do
    @moduledoc false
    use GenServer
    use Bond.Server

    @transition_invariant monotonic: new_state.n >= old_state.n

    @impl true
    def init(n), do: {:ok, %{n: n}}

    @impl true
    def handle_cast(:inc, %{n: n} = s), do: {:noreply, %{s | n: n + 1}}
    def handle_cast(:dec, %{n: n} = s), do: {:noreply, %{s | n: n - 1}}
  end

  defmodule UnguardedBank do
    @moduledoc false
    use GenServer
    use Bond.Server

    @state_invariant non_negative: state.balance >= 0

    @impl true
    def init(balance), do: {:ok, %{balance: balance}}

    # Unguarded: an over-withdrawal drives the balance negative, violating the invariant on the
    # returned state (so a `call` op can trigger the violation, not just an async message).
    @impl true
    def handle_call({:withdraw, amount}, _from, %{balance: b} = s),
      do: {:reply, :ok, %{s | balance: b - amount}}
  end

  describe "generator/2" do
    test "produces {category, message} ops with idiomatic message shapes" do
      gen =
        ServerSequence.generator(
          call: [{:withdraw, [StreamData.integer(1..5)]}],
          info: [{:corrupt, []}]
        )

      ops = gen |> Enum.take(80) |> List.flatten() |> Enum.uniq()

      refute ops == []
      assert Enum.all?(ops, fn {category, _msg} -> category in [:call, :info] end)
      # No-arg message is a bare atom; argument-bearing message is a tuple.
      assert {:info, :corrupt} in ops

      assert Enum.any?(ops, fn
               {:call, {:withdraw, n}} -> is_integer(n)
               _ -> false
             end)
    end

    test "raises when :messages is empty" do
      assert_raise ArgumentError, ~r/non-empty `:messages`/, fn ->
        ServerSequence.generator([])
      end
    end
  end

  describe "run_callbacks/3" do
    test "threads state through call/cast and returns :ok while the invariant holds" do
      ops = [{:cast, {:deposit, 10}}, {:call, {:withdraw, 5}}, {:call, :balance}]
      assert ServerSequence.run_callbacks(SafeBank, 0, ops) == :ok
    end

    test "an over-withdrawal is declined, not a violation (state unchanged)" do
      # Withdrawing more than the balance hits the guarded clause; the invariant still holds.
      assert ServerSequence.run_callbacks(SafeBank, 3, [{:call, {:withdraw, 99}}]) == :ok
    end

    test "raises the state-invariant error when a callback breaks the invariant" do
      error =
        assert_raise Bond.InvariantError, fn ->
          ServerSequence.run_callbacks(LeakyBank, 5, [{:info, :corrupt}])
        end

      assert error.kind == :state_invariant
    end

    test "fires the transition invariant using the threaded state as old_state" do
      # init n=1, then :dec -> new n=0; monotonic (new >= old) is violated by the transition.
      error =
        assert_raise Bond.InvariantError, fn ->
          ServerSequence.run_callbacks(MonotonicCounter, 1, [{:cast, :dec}])
        end

      assert error.kind == :transition_invariant
    end

    test "a :stop return terminates the sequence cleanly" do
      # Nothing to assert beyond: no raise, returns :ok. StopServer stops on :halt.
      defmodule StopServer do
        @moduledoc false
        use GenServer
        use Bond.Server
        @impl true
        def init(_), do: {:ok, %{}}
        @impl true
        def handle_info(:halt, s), do: {:stop, :normal, s}
        @impl true
        def handle_cast(:noop, s), do: {:noreply, s}
      end

      # The :halt op stops; the trailing :noop is never threaded (would be fine anyway).
      assert ServerSequence.run_callbacks(StopServer, :ok, [{:info, :halt}, {:cast, :noop}]) ==
               :ok
    end
  end

  describe "run_process/3" do
    test "drives a real server and returns :ok while the invariant holds" do
      ops = [{:cast, {:deposit, 10}}, {:call, {:withdraw, 5}}, {:call, :balance}]
      assert ServerSequence.run_process(SafeBank, 0, ops) == :ok
    end

    test "surfaces a violation triggered by a synchronous call" do
      error =
        assert_raise Bond.InvariantError, fn ->
          ServerSequence.run_process(UnguardedBank, 0, [{:call, {:withdraw, 5}}])
        end

      assert error.kind == :state_invariant
    end

    test "surfaces a violation triggered by an asynchronous info message" do
      # `:corrupt` is async; the `:sys.get_state` barrier forces it to be processed and the crash
      # to be attributed here.
      error =
        assert_raise Bond.InvariantError, fn ->
          ServerSequence.run_process(LeakyBank, 5, [{:info, :corrupt}])
        end

      assert error.kind == :state_invariant
    end

    test "a callback that stops the server ends the sequence cleanly" do
      defmodule ProcStopServer do
        @moduledoc false
        use GenServer
        use Bond.Server
        @impl true
        def init(_), do: {:ok, %{}}
        @impl true
        def handle_cast(:halt, s), do: {:stop, :normal, s}
      end

      assert ServerSequence.run_process(ProcStopServer, :ok, [{:cast, :halt}]) == :ok
    end
  end

  # End-to-end: the macro generates a property that passes over random sequences of a sound server,
  # in both execution modes.
  server_invariants_hold(SafeBank,
    init: StreamData.integer(0..100),
    messages: [
      call: [{:withdraw, [StreamData.positive_integer()]}, {:balance, []}],
      cast: [{:deposit, [StreamData.positive_integer()]}]
    ]
  )

  server_invariants_hold(SafeBank,
    mode: :process,
    name: "server_invariants_hold SafeBank (process mode)",
    init: StreamData.integer(0..100),
    messages: [
      call: [{:withdraw, [StreamData.positive_integer()]}, {:balance, []}],
      cast: [{:deposit, [StreamData.positive_integer()]}]
    ]
  )
end
