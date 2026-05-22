defmodule Bond.PropertyTest.SequenceTest do
  @moduledoc """
  Direct unit tests for the `Bond.PropertyTest.Sequence` helper. Integration through the
  Form 2 `contract_holds` macro is covered separately by `property_test_form2_test.exs`.
  """

  use ExUnit.Case

  alias Bond.PropertyTest.Sequence
  alias BondTest.InvariantSmoke

  describe "generator/4" do
    test "raises ArgumentError when constructors is empty" do
      assert_raise ArgumentError, ~r/constructors/, fn ->
        Sequence.generator([], [], [])
      end
    end

    test "produces sequences with the constructor and zero or more step ops" do
      gen =
        Sequence.generator(
          [{:new, [StreamData.integer(1..10)]}],
          [{:push, [StreamData.constant(:item)]}],
          [],
          max_length: 5
        )

      {ctor, steps} = Enum.at(gen, 0)

      assert {:constructor, :new, [arg]} = ctor
      assert is_integer(arg) and arg in 1..10

      assert is_list(steps)
      assert length(steps) <= 5

      for step <- steps do
        assert {:transformer, :push, [:item]} = step
      end
    end

    test "with empty transformers and observers, sequences have no steps" do
      gen = Sequence.generator([{:new, [StreamData.integer(1..10)]}], [], [])
      {_ctor, steps} = Enum.at(gen, 0)
      assert steps == []
    end
  end

  describe "run/2" do
    test "runs a valid sequence without raising" do
      sequence =
        {{:constructor, :new, [5]},
         [
           {:transformer, :push, [:a]},
           {:transformer, :push, [:b]}
         ]}

      assert :ok = Sequence.run(InvariantSmoke, sequence)
    end

    test "halts cleanly on a transformer that returns {:error, _}" do
      # try_new/1 with a non-integer returns {:error, :invalid_capacity}; using it as a
      # constructor exercises the constructor-side error short-circuit.
      sequence = {{:constructor, :try_new, [:not_an_integer]}, []}
      assert :ok = Sequence.run(InvariantSmoke, sequence)
    end

    test "extracts the struct from a constructor that returns {:ok, struct}" do
      sequence = {{:constructor, :try_new, [3]}, [{:transformer, :push, [:a]}]}

      assert :ok = Sequence.run(InvariantSmoke, sequence)
    end

    test "raises ArgumentError when a transformer returns an unsupported shape" do
      # capacity/1 returns an integer, not a struct — invalid as a transformer.
      sequence = {{:constructor, :new, [3]}, [{:transformer, :capacity, []}]}

      assert_raise ArgumentError, ~r/unsupported shape/, fn ->
        Sequence.run(InvariantSmoke, sequence)
      end
    end

    test "lets Bond.InvariantError propagate when the invariant is violated" do
      # broken_push/2 in the fixture intentionally produces a struct that violates
      # `size_within_capacity`. The post-invariant check on the def fires and raises.
      sequence = {{:constructor, :new, [2]}, [{:transformer, :broken_push, [:item]}]}

      assert_raise Bond.InvariantError, fn ->
        Sequence.run(InvariantSmoke, sequence)
      end
    end

    test "observers don't advance state but still fire pre-invariant" do
      sequence =
        {{:constructor, :new, [5]},
         [
           {:observer, :capacity, []},
           {:transformer, :push, [:a]},
           {:observer, :capacity, []}
         ]}

      assert :ok = Sequence.run(InvariantSmoke, sequence)
    end
  end
end
