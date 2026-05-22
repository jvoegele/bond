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

  describe "should_evaluate?/2" do
    test "returns true when runtime config is unset and compile_default is true" do
      Application.delete_env(:bond, :preconditions)
      assert Eval.should_evaluate?(:preconditions, true)
    end

    test "returns false when runtime config is unset and compile_default is false" do
      Application.delete_env(:bond, :preconditions)
      refute Eval.should_evaluate?(:preconditions, false)
    end

    test "returns false when runtime config is false regardless of compile_default" do
      Application.put_env(:bond, :preconditions, false)
      on_exit(fn -> Application.delete_env(:bond, :preconditions) end)

      refute Eval.should_evaluate?(:preconditions, true)
      refute Eval.should_evaluate?(:preconditions, false)
    end

    test "returns true when runtime config is true regardless of compile_default" do
      Application.put_env(:bond, :postconditions, true)
      on_exit(fn -> Application.delete_env(:bond, :postconditions) end)

      assert Eval.should_evaluate?(:postconditions, false)
      assert Eval.should_evaluate?(:postconditions, true)
    end
  end

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

  describe "evaluate_check/1" do
    test "returns the value of the check expression on success" do
      assert 42 == Eval.evaluate_check(fn -> 42 end)
    end

    test "raises CheckError when the assertions function throws" do
      info = %{@info | kind: :check}

      assert_raise Bond.CheckError, fn ->
        Eval.evaluate_check(fn -> throw({:assertion_failure, info}) end)
      end
    end
  end

  describe "stack trace pruning" do
    test "raised exception's stack trace contains no Bond.* frames" do
      info = %{@info | kind: :precondition}

      stacktrace =
        try do
          Eval.evaluate_preconditions(fn -> throw({:assertion_failure, info}) end)
          flunk("expected raise")
        rescue
          _ -> __STACKTRACE__
        end

      bond_frames =
        Enum.filter(stacktrace, fn
          {module, _fun, _arity, _loc} when is_atom(module) ->
            module_name = Atom.to_string(module)

            module_name == "Elixir.Bond" or
              String.starts_with?(module_name, "Elixir.Bond.")

          _ ->
            false
        end)

      assert bond_frames == [], "expected no Bond.* frames, got: #{inspect(bond_frames)}"
    end

    test "filters generated __bond_* function frames from the user's module" do
      info = %{@info | kind: :precondition}

      stacktrace =
        try do
          Eval.evaluate_preconditions(fn -> throw({:assertion_failure, info}) end)
          flunk("expected raise")
        rescue
          _ -> __STACKTRACE__
        end

      bond_generated_frames =
        Enum.filter(stacktrace, fn
          {_module, fun, _arity, _loc} when is_atom(fun) ->
            String.starts_with?(Atom.to_string(fun), "__bond_")

          _ ->
            false
        end)

      assert bond_generated_frames == []
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
