defmodule Bond.CompileStateFSMTest do
  @moduledoc false

  use ExUnit.Case

  alias Bond.CompileStateFSM, as: FSM

  @doc_attribute {:doc, [line: __ENV__.line], "The D.O.C. and the Doctor"}
  @doc_attribute_keyword {:doc, [line: __ENV__.line],
                          [artist: "The D.O.C.", title: "Portrait of a Master Piece"]}

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
    end

    test "precondition_def event", %{fsm: fsm} do
      FSM.precondition_def(fsm, :requires)
      assert FSM.current_state(fsm) == :contracts_pending
      assert FSM.pending_preconditions(fsm) == [:requires]
    end

    test "postcondition_def event", %{fsm: fsm} do
      FSM.postcondition_def(fsm, :ensures)
      assert FSM.current_state(fsm) == :contracts_pending
      assert FSM.pending_postconditions(fsm) == [:ensures]
    end

    test "doc_attribute event", %{fsm: fsm} do
      FSM.doc_attribute(fsm, @doc_attribute)
      FSM.doc_attribute(fsm, @doc_attribute_keyword)
      assert FSM.current_state(fsm) == :contracts_pending
      assert FSM.pending_doc_attributes(fsm) == [@doc_attribute, @doc_attribute_keyword]
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
  end

  describe ":contracts_pending state" do
    setup %{fsm: fsm} do
      set_state(fsm, :contracts_pending)
      {:ok, fsm: fsm}
    end

    test "function_def event", %{fsm: fsm} do
      FSM.function_def(fsm, function_def(:foo))
      assert FSM.current_state(fsm) == :contracts_apply
      assert FSM.pending_preconditions(fsm) == []
      assert FSM.pending_postconditions(fsm) == []
      assert FSM.pending_doc_attributes(fsm) == []
    end

    test "precondition_def event", %{fsm: fsm} do
      FSM.precondition_def(fsm, :requires)
      assert FSM.current_state(fsm) == :contracts_pending
      assert FSM.pending_preconditions(fsm) == [:requires]
    end

    test "postcondition_def event", %{fsm: fsm} do
      FSM.postcondition_def(fsm, :ensures)
      assert FSM.current_state(fsm) == :contracts_pending
      assert FSM.pending_postconditions(fsm) == [:ensures]
    end

    test "doc_attribute event", %{fsm: fsm} do
      FSM.doc_attribute(fsm, @doc_attribute)
      FSM.doc_attribute(fsm, @doc_attribute_keyword)
      assert FSM.current_state(fsm) == :contracts_pending
      assert FSM.pending_doc_attributes(fsm) == [@doc_attribute, @doc_attribute_keyword]
    end
  end

  describe ":contracts_apply state" do
    setup %{fsm: fsm} do
      set_state(fsm, :contracts_apply)
      {:ok, fsm: fsm}
    end

    test "function_def event", %{fsm: fsm} do
      FSM.function_def(fsm, function_def(:foo))
      assert FSM.current_state(fsm) == :no_contracts_pending
    end

    test "precondition_def event", %{fsm: fsm} do
      FSM.precondition_def(fsm, :requires)
      assert FSM.current_state(fsm) == :contracts_pending
      assert FSM.pending_preconditions(fsm) == [:requires]
    end

    test "postcondition_def event", %{fsm: fsm} do
      FSM.postcondition_def(fsm, :ensures)
      assert FSM.current_state(fsm) == :contracts_pending
      assert FSM.pending_postconditions(fsm) == [:ensures]
    end

    test "doc_attribute event", %{fsm: fsm} do
      FSM.doc_attribute(fsm, @doc_attribute)
      FSM.doc_attribute(fsm, @doc_attribute_keyword)
      assert FSM.current_state(fsm) == :contracts_pending
      assert FSM.pending_doc_attributes(fsm) == [@doc_attribute, @doc_attribute_keyword]
    end
  end

  describe "functions with multiple clauses" do
    setup %{fsm: fsm} do
      FSM.precondition_def(fsm, :requires1)
      FSM.precondition_def(fsm, :requires2)
      FSM.postcondition_def(fsm, :ensures1)
      FSM.postcondition_def(fsm, :ensures2)
      FSM.doc_attribute(fsm, @doc_attribute)
      FSM.doc_attribute(fsm, @doc_attribute_keyword)

      {:ok, fsm: fsm}
    end

    test "contracts apply to all clauses of functions with same name and arity", %{fsm: fsm} do
      assert FSM.current_state(fsm) == :contracts_pending
      assert FSM.pending_preconditions(fsm) == [:requires1, :requires2]
      assert FSM.pending_postconditions(fsm) == [:ensures1, :ensures2]
      assert FSM.pending_doc_attributes(fsm) == [@doc_attribute, @doc_attribute_keyword]

      FSM.function_def(fsm, function_def(:fn1, [:x, :y]))
      assert FSM.current_state(fsm) == :contracts_apply
      assert FSM.pending_preconditions(fsm) == [:requires1, :requires2]
      assert FSM.pending_postconditions(fsm) == [:ensures1, :ensures2]
      assert FSM.pending_doc_attributes(fsm) == [@doc_attribute, @doc_attribute_keyword]

      FSM.doc_attributes_applied(fsm)

      FSM.function_def(fsm, function_def(:fn1, [:a, :b]))
      assert FSM.current_state(fsm) == :contracts_apply
      assert FSM.pending_preconditions(fsm) == [:requires1, :requires2]
      assert FSM.pending_postconditions(fsm) == [:ensures1, :ensures2]
      assert FSM.pending_doc_attributes(fsm) == []

      FSM.function_def(fsm, function_def(:fn2, [:x, :y]))
      assert FSM.current_state(fsm) == :no_contracts_pending
      assert FSM.pending_preconditions(fsm) == []
      assert FSM.pending_postconditions(fsm) == []
      assert FSM.pending_doc_attributes(fsm) == []
    end

    test "contracts cannot be defined in between clauses of functions", %{fsm: fsm} do
      assert FSM.current_state(fsm) == :contracts_pending
      assert FSM.pending_preconditions(fsm) == [:requires1, :requires2]
      assert FSM.pending_postconditions(fsm) == [:ensures1, :ensures2]
      assert FSM.pending_doc_attributes(fsm) == [@doc_attribute, @doc_attribute_keyword]

      FSM.function_def(fsm, function_def(:fn1, [:x, :y]))
      assert FSM.current_state(fsm) == :contracts_apply
      assert FSM.pending_preconditions(fsm) == [:requires1, :requires2]
      assert FSM.pending_postconditions(fsm) == [:ensures1, :ensures2]
      assert FSM.pending_doc_attributes(fsm) == [@doc_attribute, @doc_attribute_keyword]

      FSM.precondition_def(fsm, :requires_in_between)
      FSM.postcondition_def(fsm, :ensures_in_between)
      assert FSM.current_state(fsm) == :contracts_pending
      assert FSM.pending_preconditions(fsm) == [:requires_in_between]
      assert FSM.pending_postconditions(fsm) == [:ensures_in_between]

      assert_raise CompileError, fn ->
        FSM.function_def(fsm, function_def(:fn1, [:a, :b]))
      end

      assert FSM.current_state(fsm) == :no_contracts_pending
    end
  end

  defp start_fsm(module \\ __MODULE__) do
    {:ok, fsm} = FSM.start_link(module)
    fsm
  end

  defp set_state(fsm, state) do
    :gen_statem.cast(fsm, {:set_state, state})
  end

  defp function_def(name, args \\ [:x, :y]) do
    {name, [line: 11], Enum.map(args, &{&1, [line: 11], nil})}
  end
end
