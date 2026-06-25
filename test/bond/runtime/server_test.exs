defmodule Bond.Runtime.ServerTest do
  use ExUnit.Case, async: true

  import Bond.Runtime.Server, only: [extract_state: 2]

  @state %{count: 1}

  describe "extract_state/2 — state-bearing returns" do
    test "init/1" do
      assert extract_state(:init, {:ok, @state}) == {:state, @state}
      assert extract_state(:init, {:ok, @state, :hibernate}) == {:state, @state}
      assert extract_state(:init, {:ok, @state, {:continue, :load}}) == {:state, @state}
      assert extract_state(:init, {:ok, @state, 5_000}) == {:state, @state}
    end

    test "handle_call/3" do
      assert extract_state(:handle_call, {:reply, :r, @state}) == {:state, @state}
      assert extract_state(:handle_call, {:reply, :r, @state, :hibernate}) == {:state, @state}

      assert extract_state(:handle_call, {:reply, :r, @state, {:continue, :x}}) ==
               {:state, @state}

      assert extract_state(:handle_call, {:noreply, @state}) == {:state, @state}
      assert extract_state(:handle_call, {:noreply, @state, :hibernate}) == {:state, @state}
      assert extract_state(:handle_call, {:stop, :normal, :r, @state}) == {:state, @state}
      assert extract_state(:handle_call, {:stop, :normal, @state}) == {:state, @state}
    end

    test "handle_cast/2, handle_info/2, handle_continue/2" do
      for cb <- [:handle_cast, :handle_info, :handle_continue] do
        assert extract_state(cb, {:noreply, @state}) == {:state, @state}
        assert extract_state(cb, {:noreply, @state, :hibernate}) == {:state, @state}
        assert extract_state(cb, {:noreply, @state, {:continue, :x}}) == {:state, @state}
        assert extract_state(cb, {:stop, :normal, @state}) == {:state, @state}
      end
    end

    test "code_change/3" do
      assert extract_state(:code_change, {:ok, @state}) == {:state, @state}
    end
  end

  describe "extract_state/2 — returns with no new state" do
    test "init/1 :ignore and {:stop, reason}" do
      assert extract_state(:init, :ignore) == :no_state
      assert extract_state(:init, {:stop, :bad_config}) == :no_state
    end

    test "code_change/3 {:error, reason}" do
      assert extract_state(:code_change, {:error, :incompatible}) == :no_state
    end
  end

  describe "extract_state/2 — malformed returns are not validated, just yield :no_state" do
    test "unrecognised shapes" do
      assert extract_state(:handle_call, :garbage) == :no_state
      assert extract_state(:handle_cast, {:reply, :r, @state}) == :no_state
      assert extract_state(:handle_continue, {:ok, @state}) == :no_state
      assert extract_state(:init, {:noreply, @state}) == :no_state
    end
  end
end
