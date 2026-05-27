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
end
