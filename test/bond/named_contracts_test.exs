defmodule Bond.NamedContractsTest do
  use ExUnit.Case, async: true

  # Capture-layer tests for reusable named contracts (#35). Application/attribution behaviour is
  # exercised separately once `@apply_contract` resolution lands; here we pin down that
  # `defcontract` parses, registers, and diagnoses malformed definitions at compile time.

  defp compile!(source), do: Code.compile_string(source)

  describe "defcontract capture" do
    test "a well-formed contract compiles" do
      [{mod, _} | _] =
        compile!("""
        defmodule Bond.NamedContractsTest.MoneyOK do
          use Bond

          defcontract withdrawal(account, amount) do
            @pre sufficient: amount <= account.balance
            @pre positive: amount > 0
            @post non_negative: result.balance >= 0
          end
        end
        """)

      assert mod == Bond.NamedContractsTest.MoneyOK
    end

    test "same name at different arities are distinct overloads" do
      assert [{_, _} | _] =
               compile!("""
               defmodule Bond.NamedContractsTest.Overloaded do
                 use Bond

                 defcontract positive(amount) do
                   @pre amount > 0
                 end

                 defcontract positive(amount, floor) do
                   @pre amount > floor
                 end
               end
               """)
    end

    test "a postcondition may reference result" do
      assert [{_, _} | _] =
               compile!("""
               defmodule Bond.NamedContractsTest.PostResult do
                 use Bond

                 defcontract doubler(n) do
                   @post result == n * 2
                 end
               end
               """)
    end
  end

  describe "__bond_named_contracts__/0 reflection" do
    test "exposes captured contracts keyed by {name, arity}" do
      [{mod, _} | _] =
        compile!("""
        defmodule Bond.NamedContractsTest.MoneyReflect do
          use Bond

          defcontract withdrawal(account, amount) do
            @pre sufficient: amount <= account.balance
            @post non_negative: result.balance >= 0
          end

          defcontract withdrawal(account) do
            @pre present: account != nil
          end
        end
        """)

      contracts = mod.__bond_named_contracts__()
      assert Enum.sort(Map.keys(contracts)) == [{:withdrawal, 1}, {:withdrawal, 2}]

      entry = contracts[{:withdrawal, 2}]
      assert entry.arg_names == [:account, :amount]
      assert [%{label: :sufficient, code: "amount <= account.balance"}] = entry.preconditions
      assert [%{label: :non_negative}] = entry.postconditions
    end

    test "the captured definition_env is escapable (reduced to a plain snapshot)" do
      [{mod, _} | _] =
        compile!("""
        defmodule Bond.NamedContractsTest.EnvSnapshotCheck do
          use Bond

          defcontract positive(amount) do
            @pre amount > 0
          end
        end
        """)

      env = hd(mod.__bond_named_contracts__()[{:positive, 1}].preconditions).definition_env
      # A live env's :lexical_tracker is a pid and cannot be escaped; the snapshot nils it.
      assert env.lexical_tracker == nil
      assert is_binary(env.file)
    end

    test "a module with no defcontract does not export the reflection" do
      [{mod, _} | _] =
        compile!("""
        defmodule Bond.NamedContractsTest.NoNamedContracts do
          use Bond
          def identity(x), do: x
        end
        """)

      refute function_exported?(mod, :__bond_named_contracts__, 0)
    end
  end

  describe "source_contract attribution" do
    test "a cross-module contract is named module.contract" do
      error = %Bond.PreconditionError{
        module: SomeApp.Account,
        source_contract: {SomeApp.Money, :withdrawal}
      }

      assert Bond.AssertionError.attribution(error) == " (from contract SomeApp.Money.withdrawal)"
    end

    test "a same-module contract abbreviates to :contract" do
      error = %Bond.PreconditionError{
        module: SomeApp.Money,
        source_contract: {SomeApp.Money, :withdrawal}
      }

      assert Bond.AssertionError.attribution(error) == " (from contract :withdrawal)"
    end

    test "no attribution when source_contract is nil" do
      assert Bond.AssertionError.attribution(%Bond.PreconditionError{module: M}) == ""
    end
  end

  describe "defcontract diagnostics" do
    test "empty body" do
      assert_raise CompileError, ~r/declares no @pre\/@post/, fn ->
        compile!(
          "defmodule Bond.NamedContractsTest.E1 do\n use Bond\n defcontract foo(x) do\n end\nend"
        )
      end
    end

    test "non-pre/post statement in body" do
      assert_raise CompileError, ~r/only @pre and @post/, fn ->
        compile!("""
        defmodule Bond.NamedContractsTest.E2 do
          use Bond
          defcontract foo(x) do
            @pre x > 0
            x + 1
          end
        end
        """)
      end
    end

    test "non-variable parameter" do
      assert_raise CompileError, ~r/is not a simple variable/, fn ->
        compile!("""
        defmodule Bond.NamedContractsTest.E3 do
          use Bond
          defcontract foo(%{a: a}) do
            @pre a > 0
          end
        end
        """)
      end
    end

    test "missing parameter list" do
      assert_raise CompileError, ~r/needs a parameter list/, fn ->
        compile!(
          "defmodule Bond.NamedContractsTest.E4 do\n use Bond\n defcontract foo do\n @pre true\n end\nend"
        )
      end
    end

    test "reference to an undeclared name" do
      assert_raise CompileError, ~r/which is not a contract argument/, fn ->
        compile!(
          "defmodule Bond.NamedContractsTest.E5 do\n use Bond\n defcontract foo(x) do\n @pre y > 0\n end\nend"
        )
      end
    end

    test "duplicate name/arity" do
      assert_raise CompileError, ~r/is already defined/, fn ->
        compile!("""
        defmodule Bond.NamedContractsTest.E6 do
          use Bond
          defcontract foo(x) do
            @pre x > 0
          end
          defcontract foo(y) do
            @pre y < 9
          end
        end
        """)
      end
    end

    test "bare-and-labelled mix on one @pre" do
      assert_raise CompileError, ~r/accepts a single argument/, fn ->
        compile!("""
        defmodule Bond.NamedContractsTest.E7 do
          use Bond
          defcontract foo(x) do
            @pre is_integer(x), positive: x > 0
          end
        end
        """)
      end
    end

    test "defcontract without a do block" do
      assert_raise CompileError, ~r/requires a `do/, fn ->
        compile!("defmodule Bond.NamedContractsTest.E8 do\n use Bond\n defcontract foo(x)\nend")
      end
    end
  end
end
