defmodule BondTest.StackTest do
  @moduledoc """
  Test the `BondTest.Stack` module defined in `test/support/bond_test/stack.ex`.
  """

  use ExUnit.Case

  alias Bond.PreconditionError
  alias BondTest.Stack

  describe "new/1" do
    test "creates a new empty stack with specified capacity" do
      stack = Stack.new(100)
      assert Stack.capacity(stack) == 100
      assert Stack.empty?(stack)
    end

    test "raises PreconditionError when given a capacity less than 1" do
      assert_raise PreconditionError, fn -> Stack.new(0) end
      assert_raise PreconditionError, fn -> Stack.new(-1) end
    end
  end

  describe "push/2" do
    test "pushes element on top of stack" do
      stack = Stack.new(10)
      assert Stack.size(stack) == 0

      Stack.push(stack, :foo)
      assert Stack.size(stack) == 1
      assert Stack.top(stack) == :foo

      Stack.push(stack, :bar)
      assert Stack.size(stack) == 2
      assert Stack.top(stack) == :bar
    end

    test "raises PreconditionError if stack is full" do
      stack = Stack.new(1)
      Stack.push(stack, :foo)

      assert_raise PreconditionError, fn -> Stack.push(stack, :bar) end
    end
  end

  describe "pop/1" do
    test "pops top element from stack" do
      stack = Stack.new(10)
      Stack.push(stack, :foo)
      Stack.push(stack, :bar)
      Stack.push(stack, :baz)

      assert Stack.pop(stack) == :baz
      assert Stack.pop(stack) == :bar
      assert Stack.pop(stack) == :foo
    end

    test "raises PreconditionError if stack is empty" do
      stack = Stack.new(10)
      Stack.push(stack, :foo)

      assert Stack.pop(stack) == :foo
      assert_raise PreconditionError, fn -> Stack.pop(stack) end
    end
  end
end
