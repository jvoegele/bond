defmodule ContractConsumerTest do
  @moduledoc """
  Smoke tests confirming the Bond-wrapped functions actually run (the
  generated code executes, not just compiles) and that contracts fire on
  violation. The primary value of this project is the compile and Dialyzer
  steps in CI; these tests just prove the generated code is live.
  """
  use ExUnit.Case

  alias ContractConsumer.Account
  alias ContractConsumer.BoundedStack
  alias ContractConsumer.Classifier
  alias ContractConsumer.Increment
  alias ContractConsumer.Stats
  alias ContractConsumer.TypedGuard
  alias ContractConsumer.TypedInvariant

  test "single-clause contract passes on valid input" do
    assert Account.withdraw(100, 30) == 70
  end

  test "precondition fires on violation" do
    assert_raise Bond.PreconditionError, fn -> Account.withdraw(100, 0) end
  end

  test "multi-clause dispatch is preserved under wrapping" do
    assert Classifier.classify("hello") == :string
    assert Classifier.classify(42) == :integer
  end

  test "default argument clause is wrapped correctly" do
    assert Increment.bump(5) == 6
    assert Increment.bump(5, 10) == 15
  end

  test "invariant and old/1 postcondition hold across a struct operation" do
    stack = BoundedStack.new(3)
    assert BoundedStack.size(stack) == 0

    pushed = BoundedStack.push(stack, :a)
    assert BoundedStack.size(pushed) == 1
  end

  test "inline check passes on valid input" do
    assert Stats.mean([2, 4, 6]) == 4.0
  end

  describe "tautological-assertion fixtures (regression for dialyzer pattern_match warnings)" do
    test "typespec-implied @pre runs and validates" do
      assert TypedGuard.stringify("hi") == "hi!"
      assert TypedGuard.atom_label(:foo) == "foo"
    end

    test "typespec-implied @post runs and validates" do
      assert TypedGuard.key_to_string(:bar) == "bar"
    end

    test "~> antecedent that's a tautological guard still fires the consequent" do
      assert TypedGuard.normalize({:ok, 1}) == :ok
    end

    test "<~ pattern that's a typespec-exhaustive match still returns true on success" do
      assert TypedGuard.wrap(7) == {:ok, 7}
    end

    test "tautological @invariant on a struct still runs cleanly" do
      state = TypedInvariant.new("starting", 0)
      assert TypedInvariant.increment(state).count == 1
    end
  end
end
