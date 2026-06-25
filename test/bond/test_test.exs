defmodule Bond.TestTest do
  @moduledoc """
  Tests for `Bond.Test` ExUnit helpers. Uses the existing `BondTest.Math` fixture as the
  module-under-test.
  """

  use ExUnit.Case
  use Bond.Test

  alias BondTest.Math

  describe "assert_precondition_violation/2" do
    test "passes when the expected precondition is raised" do
      error = assert_precondition_violation(Math.sqrt(-1))

      assert is_struct(error, Bond.PreconditionError)
      assert error.label == :non_negative_x
    end

    test "passes when expected fields match exactly" do
      assert_precondition_violation(Math.sqrt(-1),
        label: :non_negative_x,
        expression: "x >= 0",
        module: BondTest.Math,
        function: {:sqrt, 2}
      )
    end

    test "passes when expression is matched by a regex" do
      assert_precondition_violation(Math.sqrt("NaN"),
        label: :numeric_x,
        expression: ~r/is_number/
      )
    end

    test "fails when no precondition violation occurs" do
      assert_raise ExUnit.AssertionError, fn ->
        assert_precondition_violation(Math.sqrt(4))
      end
    end

    test "fails when expected field does not match" do
      assert_raise ExUnit.AssertionError, ~r/expected.*label.*to match :wrong_label/, fn ->
        assert_precondition_violation(Math.sqrt(-1), label: :wrong_label)
      end
    end

    test "returns the exception so further assertions can be made" do
      error = assert_precondition_violation(Math.sqrt(-1))
      assert error.binding[:x] == -1
    end
  end

  describe "assert_postcondition_violation/2" do
    test "passes when the expected postcondition is raised" do
      error = assert_postcondition_violation(Math.sqrt(2, fn _ -> 10 end))

      assert is_struct(error, Bond.PostconditionError)
      assert error.function == {:sqrt, 2}
    end

    test "fails when no postcondition violation occurs" do
      assert_raise ExUnit.AssertionError, fn ->
        assert_postcondition_violation(Math.sqrt(4))
      end
    end
  end

  defmodule CheckFixture do
    @moduledoc false
    use Bond

    def must_be_positive(n) do
      check positive_n: n > 0
      n
    end
  end

  describe "assert_check_violation/2" do
    test "passes when the expected check is raised" do
      error = assert_check_violation(CheckFixture.must_be_positive(-1))

      assert is_struct(error, Bond.CheckError)
      assert error.label == :positive_n
    end

    test "passes when expected fields match exactly" do
      assert_check_violation(CheckFixture.must_be_positive(-1),
        label: :positive_n,
        expression: "n > 0"
      )
    end

    test "fails when no check violation occurs" do
      assert_raise ExUnit.AssertionError, fn ->
        assert_check_violation(CheckFixture.must_be_positive(1))
      end
    end
  end

  defmodule ServerFixture do
    @moduledoc false
    use GenServer
    use Bond.Server

    @state_invariant non_negative: state.n >= 0
    @transition_invariant monotonic: new_state.n >= old_state.n

    @impl true
    def init(n), do: {:ok, %{n: n}}

    @impl true
    # Calling the wrapped callback directly runs super + the invariant checks synchronously.
    def handle_cast({:set, n}, s), do: {:noreply, %{s | n: n}}
  end

  describe "assert_state_invariant_violation/2" do
    test "passes when the expected state-invariant violation is raised" do
      error = assert_state_invariant_violation(ServerFixture.handle_cast({:set, -1}, %{n: 0}))

      assert is_struct(error, Bond.StateInvariantError)
      assert error.label == :non_negative
      assert error.function == {:handle_cast, 2}
    end

    test "passes when expected fields match exactly" do
      assert_state_invariant_violation(ServerFixture.handle_cast({:set, -1}, %{n: 0}),
        label: :non_negative,
        expression: "state.n >= 0"
      )
    end

    test "fails when no state-invariant violation occurs" do
      assert_raise ExUnit.AssertionError, fn ->
        assert_state_invariant_violation(ServerFixture.handle_cast({:set, 1}, %{n: 0}))
      end
    end
  end

  describe "assert_transition_invariant_violation/2" do
    test "passes when the expected transition-invariant violation is raised" do
      # State invariant holds (2 >= 0); the transition invariant does not (2 < 5).
      error = assert_transition_invariant_violation(ServerFixture.handle_cast({:set, 2}, %{n: 5}))

      assert is_struct(error, Bond.TransitionInvariantError)
      assert error.label == :monotonic
      assert error.binding == [new_state: %{n: 2}, old_state: %{n: 5}]
    end

    test "fails when the transition holds" do
      assert_raise ExUnit.AssertionError, fn ->
        assert_transition_invariant_violation(ServerFixture.handle_cast({:set, 9}, %{n: 5}))
      end
    end
  end
end
