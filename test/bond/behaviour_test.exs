defmodule Bond.BehaviourTest do
  use ExUnit.Case, async: true

  alias Bond.Compiler.Assertion

  defmodule Ledger do
    use Bond.Behaviour

    @pre positive_amount: amount > 0
    @post non_negative: result >= 0
    @callback withdraw(balance :: non_neg_integer, amount :: pos_integer) :: non_neg_integer

    # Bare (unlabelled) contract form, plus an uncontracted callback in between.
    @callback describe(balance :: non_neg_integer) :: String.t()

    @pre amount > 0
    @callback deposit(balance :: non_neg_integer, amount :: pos_integer) :: non_neg_integer
  end

  describe "__bond_contracts__/0" do
    test "keys contracts by {name, arity}" do
      contracts = Ledger.__bond_contracts__()
      assert Map.has_key?(contracts, {:withdraw, 2})
      assert Map.has_key?(contracts, {:deposit, 2})
    end

    test "records callback argument names as the canonical positional names" do
      %{arg_names: names} = Ledger.__bond_contracts__()[{:withdraw, 2}]
      assert names == [:balance, :amount]
    end

    test "captures the labelled precondition and postcondition for a callback" do
      %{preconditions: [pre], postconditions: [post]} =
        Ledger.__bond_contracts__()[{:withdraw, 2}]

      assert %Assertion{kind: :precondition, label: :positive_amount, code: "amount > 0"} = pre
      assert %Assertion{kind: :postcondition, label: :non_negative, code: "result >= 0"} = post
    end

    test "captures bare (unlabelled) contracts" do
      %{preconditions: [pre]} = Ledger.__bond_contracts__()[{:deposit, 2}]
      assert %Assertion{kind: :precondition, label: nil, code: "amount > 0"} = pre
    end

    test "omits uncontracted callbacks" do
      refute Map.has_key?(Ledger.__bond_contracts__(), {:describe, 1})
    end

    test "the assertion env is escapable (no live Macro.Env leaks through)" do
      %{preconditions: [pre]} = Ledger.__bond_contracts__()[{:withdraw, 2}]
      assert pre.definition_env.module == Ledger
      assert pre.definition_env.lexical_tracker == nil
    end

    test "captured assertions record the source behaviour for attribution" do
      %{preconditions: [pre], postconditions: [post]} =
        Ledger.__bond_contracts__()[{:withdraw, 2}]

      assert pre.source_behaviour == Ledger
      assert post.source_behaviour == Ledger
    end
  end

  describe "error attribution" do
    test "precondition message names the source behaviour when inherited" do
      error = %Bond.PreconditionError{
        label: :positive_amount,
        expression: "amount > 0",
        module: BankAccount,
        function: {:withdraw, 2},
        binding: [amount: -1],
        source_behaviour: Ledger
      }

      message = Exception.message(error)
      assert message =~ "precondition (inherited from Bond.BehaviourTest.Ledger) failed"
      assert message =~ "BankAccount.withdraw/2"
    end

    test "precondition message omits attribution for a direct contract" do
      error = %Bond.PreconditionError{
        label: nil,
        expression: "x > 0",
        module: Foo,
        function: {:bar, 1},
        binding: [x: -1],
        source_behaviour: nil
      }

      refute Exception.message(error) =~ "inherited from"
    end
  end

  test "the module is still a proper behaviour" do
    callbacks = Ledger.behaviour_info(:callbacks)
    assert {:withdraw, 2} in callbacks
    assert {:describe, 1} in callbacks
    assert {:deposit, 2} in callbacks
  end

  test "@pre/@post with no following @callback is a compile error" do
    assert_raise CompileError, ~r/do not precede an @callback/, fn ->
      Code.compile_string("""
      defmodule Bond.BehaviourTest.Dangling do
        use Bond.Behaviour
        @pre x > 0
        @callback ok(x :: integer) :: integer
        @post result > 0
      end
      """)
    end
  end

  test "unnamed callback arguments get generated canonical names" do
    [{mod, _bin}] =
      Code.compile_string("""
      defmodule Bond.BehaviourTest.Unnamed do
        use Bond.Behaviour
        @pre is_integer(bond_arg_0)
        @callback f(integer) :: integer
      end
      """)

    assert %{arg_names: [:bond_arg_0]} = mod.__bond_contracts__()[{:f, 1}]
  end
end
