defmodule Bond.Runtime.EvalTest do
  @moduledoc false

  use ExUnit.Case

  alias Bond.Runtime.Eval

  @info %{
    kind: :precondition,
    label: :example,
    expression: "x > 0",
    file: "foo.ex",
    line: 1,
    module: SomeModule,
    function: {:foo, 1},
    binding: [x: -1]
  }

  describe "evaluate_preconditions/1" do
    test "invokes the given assertions function" do
      ref = make_ref()
      pid = self()

      Eval.evaluate_preconditions(fn ->
        send(pid, {:called, ref})
      end)

      assert_received {:called, ^ref}
    end

    test "raises PreconditionError when the assertions function throws" do
      info = %{@info | kind: :precondition}

      assert_raise Bond.PreconditionError, fn ->
        Eval.evaluate_preconditions(fn -> throw({:assertion_failure, info}) end)
      end
    end
  end

  describe "evaluate_postconditions/1" do
    test "raises PostconditionError when the assertions function throws" do
      info = %{@info | kind: :postcondition}

      assert_raise Bond.PostconditionError, fn ->
        Eval.evaluate_postconditions(fn -> throw({:assertion_failure, info}) end)
      end
    end
  end

  describe "evaluate_checks/1" do
    test "raises CheckError when the assertions function throws" do
      info = %{@info | kind: :check}

      assert_raise Bond.CheckError, fn ->
        Eval.evaluate_checks(fn -> throw({:assertion_failure, info}) end)
      end
    end
  end

  describe "Assertion Evaluation Rule (recursion guard)" do
    test "does not invoke the inner assertions function when already evaluating" do
      ref = make_ref()
      pid = self()

      inner = fn -> send(pid, {:inner, ref}) end
      outer = fn -> Eval.evaluate_preconditions(inner) end

      Eval.evaluate_preconditions(outer)
      refute_received {:inner, ^ref}
    end

    test "clears the recursion flag after the outer evaluation completes" do
      Eval.evaluate_preconditions(fn -> :ok end)

      ref = make_ref()
      pid = self()
      Eval.evaluate_preconditions(fn -> send(pid, {:second, ref}) end)
      assert_received {:second, ^ref}
    end

    test "clears the recursion flag even when the outer evaluation raises" do
      info = %{@info | kind: :precondition}

      assert_raise Bond.PreconditionError, fn ->
        Eval.evaluate_preconditions(fn -> throw({:assertion_failure, info}) end)
      end

      ref = make_ref()
      pid = self()
      Eval.evaluate_preconditions(fn -> send(pid, {:after_throw, ref}) end)
      assert_received {:after_throw, ^ref}
    end
  end
end
