defmodule Bond.Compiler.CompileStateFSMTest do
  @moduledoc false

  use ExUnit.Case

  alias Bond.Compiler.AnnotatedFunction
  alias Bond.Compiler.Assertion
  alias Bond.Compiler.CompileStateFSM, as: FSM
  alias Bond.Compiler.FunctionDefinition

  @doc_attribute {[line: 42], "The D.O.C. and the Doctor"}
  @doc_attribute_keyword {[line: 43], [artist: "The D.O.C.", title: "Portrait of a Master Piece"]}

  setup do
    {:ok, fsm: start_fsm()}
  end

  test "starts in :no_contracts_pending state", %{fsm: fsm} do
    assert FSM.current_state(fsm) == :no_contracts_pending
  end

  describe ":no_contracts_pending state" do
    test "function_def event", %{fsm: fsm} do
      FSM.function_def(fsm, function_def(:foo))
      assert FSM.current_state(fsm) == :no_contracts_pending
      assert [%AnnotatedFunction{fun: :foo} = fun] = FSM.annotated_functions(fsm)
      assert fun.preconditions == []
      assert fun.postconditions == []
      assert fun.doc_attributes == []
      assert [%AnnotatedFunction.Clause{}] = fun.clauses
    end

    test "precondition_def event", %{fsm: fsm} do
      FSM.precondition_def(fsm, precondition_def(:requires))
      assert FSM.current_state(fsm) == :contracts_pending
      assert [%Assertion{kind: :precondition, label: :requires}] = FSM.pending_preconditions(fsm)
      assert FSM.annotated_functions(fsm) == []
    end

    test "postcondition_def event", %{fsm: fsm} do
      FSM.postcondition_def(fsm, postcondition_def(:ensures))
      assert FSM.current_state(fsm) == :contracts_pending
      assert [%Assertion{kind: :postcondition, label: :ensures}] = FSM.pending_postconditions(fsm)
      assert FSM.annotated_functions(fsm) == []
    end

    test "doc_attribute event", %{fsm: fsm} do
      FSM.doc_attribute(fsm, @doc_attribute)
      FSM.doc_attribute(fsm, @doc_attribute_keyword)
      assert FSM.current_state(fsm) == :contracts_pending
      assert FSM.pending_doc_attributes(fsm) == [@doc_attribute, @doc_attribute_keyword]
      assert FSM.annotated_functions(fsm) == []
    end

    test "module_defined event transitions to :done state", %{fsm: fsm} do
      FSM.module_defined(fsm)
      assert FSM.current_state(fsm) == :done
    end

    test "pending_preconditions", %{fsm: fsm} do
      assert FSM.pending_preconditions(fsm) == []
    end

    test "pending_postconditions", %{fsm: fsm} do
      assert FSM.pending_postconditions(fsm) == []
    end

    test "pending_doc_attributes", %{fsm: fsm} do
      assert FSM.pending_doc_attributes(fsm) == []
    end

    test "annotated_functions", %{fsm: fsm} do
      assert FSM.annotated_functions(fsm) == []
    end
  end

  describe ":contracts_pending state" do
    setup %{fsm: fsm} do
      set_state(fsm, :contracts_pending)
      {:ok, fsm: fsm}
    end

    test "function_def event", %{fsm: fsm} do
      FSM.function_def(fsm, function_def(:foo))
      assert FSM.current_state(fsm) == :no_contracts_pending
      assert FSM.pending_preconditions(fsm) == []
      assert FSM.pending_postconditions(fsm) == []
      assert FSM.pending_doc_attributes(fsm) == []
      assert [%AnnotatedFunction{fun: :foo} = function_def] = FSM.annotated_functions(fsm)
      assert function_def.preconditions == []
      assert function_def.postconditions == []
    end

    test "precondition_def event", %{fsm: fsm} do
      FSM.precondition_def(fsm, precondition_def(:requires))
      assert FSM.current_state(fsm) == :contracts_pending
      assert [%Assertion{kind: :precondition, label: :requires}] = FSM.pending_preconditions(fsm)
      assert FSM.annotated_functions(fsm) == []
    end

    test "postcondition_def event", %{fsm: fsm} do
      FSM.postcondition_def(fsm, postcondition_def(:ensures))
      assert FSM.current_state(fsm) == :contracts_pending
      assert [%Assertion{kind: :postcondition, label: :ensures}] = FSM.pending_postconditions(fsm)
      assert FSM.annotated_functions(fsm) == []
    end

    test "doc_attribute event", %{fsm: fsm} do
      FSM.doc_attribute(fsm, @doc_attribute)
      FSM.doc_attribute(fsm, @doc_attribute_keyword)
      assert FSM.current_state(fsm) == :contracts_pending
      assert FSM.pending_doc_attributes(fsm) == [@doc_attribute, @doc_attribute_keyword]
      assert FSM.annotated_functions(fsm) == []
    end

    test "module_defined event with pending contracts triggers an error", %{fsm: fsm} do
      assert_raise CompileError, fn -> FSM.module_defined(fsm) end
      assert FSM.current_state(fsm) == :error
    end
  end

  describe ":done state" do
    setup %{fsm: fsm} do
      set_state(fsm, :done)
      {:ok, fsm: fsm}
    end

    test "function_def event", %{fsm: fsm} do
      FSM.function_def(fsm, function_def(:foo))
      assert FSM.current_state(fsm) == :done
    end
  end

  describe "functions with multiple clauses" do
    setup %{fsm: fsm} do
      FSM.precondition_def(fsm, precondition_def(:requires1))
      FSM.precondition_def(fsm, precondition_def(:requires2))
      FSM.postcondition_def(fsm, postcondition_def(:ensures1))
      FSM.postcondition_def(fsm, postcondition_def(:ensures2))
      FSM.doc_attribute(fsm, @doc_attribute)
      FSM.doc_attribute(fsm, @doc_attribute_keyword)

      {:ok, fsm: fsm}
    end

    test "contracts apply to all clauses of functions with same name and arity", %{fsm: fsm} do
      assert FSM.current_state(fsm) == :contracts_pending

      assert [
               %Assertion{kind: :precondition, label: :requires1},
               %Assertion{kind: :precondition, label: :requires2}
             ] = FSM.pending_preconditions(fsm)

      assert [
               %Assertion{kind: :postcondition, label: :ensures1},
               %Assertion{kind: :postcondition, label: :ensures2}
             ] = FSM.pending_postconditions(fsm)

      assert FSM.pending_doc_attributes(fsm) == [@doc_attribute, @doc_attribute_keyword]
      assert FSM.annotated_functions(fsm) == []

      FSM.function_def(fsm, function_def(:fn1, [:x, :y]))
      assert FSM.current_state(fsm) == :no_contracts_pending

      assert FSM.pending_preconditions(fsm) == []
      assert FSM.pending_postconditions(fsm) == []

      assert FSM.pending_doc_attributes(fsm) == []

      assert [%AnnotatedFunction{fun: :fn1} = fn1] = FSM.annotated_functions(fsm)
      assert [%AnnotatedFunction.Clause{}] = fn1.clauses

      assert [precondition1, precondition2] = fn1.preconditions
      assert [postcondition1, postcondition2] = fn1.postconditions
      assert %Assertion{kind: :precondition, label: :requires1} = precondition1
      assert %Assertion{kind: :precondition, label: :requires2} = precondition2
      assert %Assertion{kind: :postcondition, label: :ensures1} = postcondition1
      assert %Assertion{kind: :postcondition, label: :ensures2} = postcondition2

      assert fn1.doc_attributes == [
               {[line: 42], "The D.O.C. and the Doctor"},
               {[line: 43], [artist: "The D.O.C.", title: "Portrait of a Master Piece"]}
             ]

      FSM.doc_attributes_applied(fsm)

      FSM.function_def(fsm, function_def(:fn1, [:a, :b]))
      assert FSM.current_state(fsm) == :no_contracts_pending

      assert FSM.pending_preconditions(fsm) == []
      assert FSM.pending_postconditions(fsm) == []
      assert FSM.pending_doc_attributes(fsm) == []

      assert [%AnnotatedFunction{fun: :fn1} = fn1] = FSM.annotated_functions(fsm)

      assert [%AnnotatedFunction.Clause{} = clause1, %AnnotatedFunction.Clause{} = clause2] =
               fn1.clauses

      assert clause1.params == [:x, :y]
      assert clause2.params == [:a, :b]

      assert [precondition1, precondition2] = fn1.preconditions
      assert [postcondition1, postcondition2] = fn1.postconditions
      assert %Assertion{kind: :precondition, label: :requires1} = precondition1
      assert %Assertion{kind: :precondition, label: :requires2} = precondition2
      assert %Assertion{kind: :postcondition, label: :ensures1} = postcondition1
      assert %Assertion{kind: :postcondition, label: :ensures2} = postcondition2

      assert fn1.doc_attributes == [
               {[line: 42], "The D.O.C. and the Doctor"},
               {[line: 43], [artist: "The D.O.C.", title: "Portrait of a Master Piece"]}
             ]

      FSM.function_def(fsm, function_def(:fn2, [:x, :y]))
      assert FSM.current_state(fsm) == :no_contracts_pending
      assert FSM.pending_preconditions(fsm) == []
      assert FSM.pending_postconditions(fsm) == []
      assert FSM.pending_doc_attributes(fsm) == []

      assert [^fn1, %AnnotatedFunction{fun: :fn2} = fn2] = FSM.annotated_functions(fsm)

      assert fn2.preconditions == []
      assert fn2.postconditions == []

      FSM.module_defined(fsm)
      assert FSM.current_state(fsm) == :done
    end

    test "contracts cannot be defined in between clauses of functions", %{fsm: fsm} do
      assert FSM.current_state(fsm) == :contracts_pending

      assert [
               %Assertion{kind: :precondition, label: :requires1},
               %Assertion{kind: :precondition, label: :requires2}
             ] = FSM.pending_preconditions(fsm)

      assert [
               %Assertion{kind: :postcondition, label: :ensures1},
               %Assertion{kind: :postcondition, label: :ensures2}
             ] = FSM.pending_postconditions(fsm)

      assert FSM.pending_doc_attributes(fsm) == [@doc_attribute, @doc_attribute_keyword]

      FSM.function_def(fsm, function_def(:fn1, [:x, :y]))
      assert FSM.current_state(fsm) == :no_contracts_pending

      assert FSM.pending_preconditions(fsm) == []
      assert FSM.pending_postconditions(fsm) == []
      assert FSM.pending_doc_attributes(fsm) == []

      FSM.precondition_def(fsm, precondition_def(:requires_in_between))
      FSM.postcondition_def(fsm, postcondition_def(:ensures_in_between))
      assert FSM.current_state(fsm) == :contracts_pending

      assert [%Assertion{kind: :precondition, label: :requires_in_between}] =
               FSM.pending_preconditions(fsm)

      assert [%Assertion{kind: :postcondition, label: :ensures_in_between}] =
               FSM.pending_postconditions(fsm)

      assert_raise CompileError, fn ->
        FSM.function_def(fsm, function_def(:fn1, [:a, :b]))
      end

      assert FSM.current_state(fsm) == :error
    end
  end

  defp start_fsm(module \\ __MODULE__) do
    {:ok, fsm} = FSM.start_link(module)
    fsm
  end

  defp set_state(fsm, state) do
    :gen_statem.cast(fsm, {:set_state, state})
  end

  defp function_def(name, params \\ [:x, :y]) do
    FunctionDefinition.new(__ENV__, :def, name, params, [], quote(do: :ok))
  end

  defp precondition_def(label) do
    expression = quote(do: 1 + 1 == 2)
    Assertion.new(:precondition, label, expression)
  end

  defp postcondition_def(label) do
    expression = quote(do: 1 + 1 == 2)
    Assertion.new(:postcondition, label, expression)
  end
end
