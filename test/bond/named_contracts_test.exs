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

  describe "include capture (#40)" do
    test "local, remote, and includes-only forms compile; reflection strips includes" do
      compile!("""
      defmodule Bond.NamedContractsTest.IncludeLib do
        use Bond
        defcontract base(x) do
          @pre x > 0
        end
      end
      """)

      [{mod, _} | _] =
        compile!("""
        defmodule Bond.NamedContractsTest.IncludeCapture do
          use Bond
          defcontract positive(x), do: (@pre x > 0)

          defcontract checkout(cart, user) do
            include positive(cart.total)
            include Bond.NamedContractsTest.IncludeLib.base(user.id)
            @post ok: result != nil
          end
        end
        """)

      entry = mod.__bond_named_contracts__()[{:checkout, 2}]
      assert entry.arg_names == [:cart, :user]
      refute Map.has_key?(entry, :includes)
    end

    test "a malformed include is rejected" do
      assert_raise CompileError, ~r/expects a contract call/, fn ->
        compile!("""
        defmodule Bond.NamedContractsTest.BadInclude do
          use Bond
          defcontract c(x) do
            include 123
          end
        end
        """)
      end
    end

    test "an include argument referencing a non-argument is rejected" do
      assert_raise CompileError, ~r/which is not an argument of contract c/, fn ->
        compile!("""
        defmodule Bond.NamedContractsTest.BadIncludeArg do
          use Bond
          defcontract p(x), do: (@pre x > 0)
          defcontract c(cart) do
            include p(user.id)
          end
        end
        """)
      end
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

  describe "@apply_contract capture" do
    test "applying a local contract compiles and the function works for valid input" do
      [{mod, _} | _] =
        compile!("""
        defmodule Bond.NamedContractsTest.ApplyLocal do
          use Bond

          defcontract positive(x) do
            @pre x > 0
          end

          @apply_contract :positive
          def double(n), do: n * 2
        end
        """)

      assert mod.double(5) == 10
    end

    test "the {Module, :name} remote form compiles" do
      compile!("""
      defmodule Bond.NamedContractsTest.ApplyLib do
        use Bond
        defcontract a(x) do
          @pre x > 0
        end
      end
      """)

      assert [{_, _} | _] =
               compile!("""
               defmodule Bond.NamedContractsTest.ApplyRemote do
                 use Bond

                 @apply_contract {Bond.NamedContractsTest.ApplyLib, :a}
                 def g(n), do: n
               end
               """)
    end

    test "the list (multiple-contract) form is rejected in v1" do
      assert_raise CompileError, ~r/single named contract in v1/, fn ->
        compile!("""
        defmodule Bond.NamedContractsTest.ListForm do
          use Bond
          defcontract p(x) do
            @pre x > 0
          end
          @apply_contract [:p, :p]
          def f(x), do: x
        end
        """)
      end
    end

    test "two @apply_contract lines on one function are rejected in v1" do
      assert_raise CompileError, ~r/applies more than one named contract/, fn ->
        compile!("""
        defmodule Bond.NamedContractsTest.TwoLines do
          use Bond
          defcontract a(x) do
            @pre x > 0
          end
          defcontract b(x) do
            @pre x < 9
          end
          @apply_contract :a
          @apply_contract :b
          def f(x), do: x
        end
        """)
      end
    end

    test "a dangling @apply_contract with no following def is rejected" do
      assert_raise CompileError, ~r/do not precede a function/, fn ->
        compile!("""
        defmodule Bond.NamedContractsTest.Dangling do
          use Bond
          defcontract p(x) do
            @pre x > 0
          end
          @apply_contract :p
        end
        """)
      end
    end

    test "@apply_contract between clauses is rejected" do
      assert_raise CompileError, ~r/in between clauses/, fn ->
        compile!("""
        defmodule Bond.NamedContractsTest.BetweenClauses do
          use Bond
          defcontract p(x) do
            @pre x > 0
          end
          def h(1), do: :one
          @apply_contract :p
          def h(2), do: :two
        end
        """)
      end
    end

    test "an invalid reference is rejected" do
      assert_raise CompileError, ~r/expects a contract name/, fn ->
        compile!("""
        defmodule Bond.NamedContractsTest.BadRef do
          use Bond
          @apply_contract 123
          def k(x), do: x
        end
        """)
      end
    end

    test "the comma (multi-arg) form is rejected" do
      assert_raise CompileError, ~r/accepts a single contract reference/, fn ->
        compile!("""
        defmodule Bond.NamedContractsTest.CommaForm do
          use Bond
          @apply_contract :a, :b
          def k(x), do: x
        end
        """)
      end
    end
  end

  describe "@apply_contract enforcement" do
    test "a cross-module contract is enforced with positional rebind and attribution" do
      compile!("""
      defmodule Bond.NamedContractsTest.Money do
        use Bond
        defcontract withdrawal(account, amount) do
          @pre positive: amount > 0
          @pre sufficient: amount <= account.balance
          @post non_negative: result.balance >= 0
        end
      end
      """)

      [{mod, _} | _] =
        compile!("""
        defmodule Bond.NamedContractsTest.Account do
          use Bond
          @apply_contract {Bond.NamedContractsTest.Money, :withdrawal}
          def withdraw(acct, amt), do: %{acct | balance: acct.balance - amt}
        end
        """)

      assert mod.withdraw(%{balance: 100}, 30) == %{balance: 70}

      error = assert_raise Bond.PreconditionError, fn -> mod.withdraw(%{balance: 100}, -5) end
      message = Exception.message(error)
      assert message =~ "from contract Bond.NamedContractsTest.Money.withdrawal"
      assert message =~ "Bond.NamedContractsTest.Account.withdraw/2"
    end

    test "a local contract abbreviates attribution and overloads by arity" do
      [{mod, _} | _] =
        compile!("""
        defmodule Bond.NamedContractsTest.LocalApply do
          use Bond
          defcontract positive(x) do
            @pre x > 0
          end
          defcontract positive(x, floor) do
            @pre x > floor
          end
          @apply_contract :positive
          def f(n), do: n
          @apply_contract :positive
          def g(n, floor), do: n - floor
        end
        """)

      assert mod.f(3) == 3
      assert mod.g(5, 2) == 3

      error = assert_raise Bond.PreconditionError, fn -> mod.f(-1) end
      assert Exception.message(error) =~ "from contract :positive"
      assert_raise Bond.PreconditionError, fn -> mod.g(1, 5) end
    end

    test "a postcondition over result is enforced" do
      [{mod, _} | _] =
        compile!("""
        defmodule Bond.NamedContractsTest.PostApply do
          use Bond
          defcontract doubler(n) do
            @post result == n * 2
          end
          @apply_contract :doubler
          def twice(x), do: x * 2
          @apply_contract :doubler
          def broken(x), do: x * 3
        end
        """)

      assert mod.twice(4) == 8
      assert_raise Bond.PostconditionError, fn -> mod.broken(4) end
    end

    test "the failure telemetry event carries source_contract" do
      [{mod, _} | _] =
        compile!("""
        defmodule Bond.NamedContractsTest.TelemetryApply do
          use Bond
          defcontract positive(x) do
            @pre x > 0
          end
          @apply_contract :positive
          def f(n), do: n
        end
        """)

      handler = {__MODULE__, :"telemetry-#{System.unique_integer([:positive])}"}
      test_pid = self()

      :telemetry.attach(
        handler,
        [:bond, :assertion, :failure],
        fn _event, _measurements, metadata, _ -> send(test_pid, {:bond_failure, metadata}) end,
        nil
      )

      assert_raise Bond.PreconditionError, fn -> mod.f(-1) end
      assert_received {:bond_failure, %{source_contract: {mod_in_event, :positive}}}
      assert mod_in_event == mod

      :telemetry.detach(handler)
    end
  end

  describe "cross-module application (mix-compiled support modules)" do
    test "a remote contract is enforced across the compile boundary" do
      assert BondTest.NamedContractConsumer.withdraw(%{balance: 100}, 40) == %{balance: 60}

      assert_raise Bond.PreconditionError, fn ->
        BondTest.NamedContractConsumer.withdraw(%{balance: 100}, 200)
      end
    end

    test "the overload is selected by the applying function's arity" do
      assert BondTest.NamedContractConsumer.only_positive(5) == 5
      assert BondTest.NamedContractConsumer.above_floor(9, 2) == 7

      assert_raise Bond.PreconditionError, fn ->
        BondTest.NamedContractConsumer.only_positive(-1)
      end

      assert_raise Bond.PreconditionError, fn ->
        BondTest.NamedContractConsumer.above_floor(1, 5)
      end
    end
  end

  describe "multi-clause and configuration" do
    test "an applied contract binds positionally across every clause" do
      [{mod, _} | _] =
        compile!("""
        defmodule Bond.NamedContractsTest.MultiClause do
          use Bond
          defcontract described(n) do
            @pre is_integer(n)
            @post is_binary(result)
          end
          @apply_contract :described
          def describe(0), do: "zero"
          def describe(n) when n > 0, do: "positive"
          def describe(n) when n < 0, do: "negative"
        end
        """)

      assert mod.describe(0) == "zero"
      assert mod.describe(7) == "positive"
      assert mod.describe(-7) == "negative"
      # A clause matches (1.5 > 0) but the rebound `n` fails the contract's is_integer/1 pre.
      assert_raise Bond.PreconditionError, fn -> mod.describe(1.5) end
    end

    test "an applied contract honours the consuming module's :purge config" do
      [{mod, _} | _] =
        compile!("""
        defmodule Bond.NamedContractsTest.PurgedApply do
          use Bond, preconditions: :purge, postconditions: :purge, invariants: :purge
          defcontract positive(x) do
            @pre x > 0
          end
          @apply_contract :positive
          def f(n), do: n
        end
        """)

      # The precondition is purged at compile time on this module, so an otherwise-failing
      # argument passes straight through.
      assert mod.f(-5) == -5
    end
  end

  describe "@apply_contract extension (additive own clauses, #40)" do
    test "own @pre/@post are conjoined with the applied contract and attributed to the function" do
      [{mod, _} | _] =
        compile!("""
        defmodule Bond.NamedContractsTest.Extended do
          use Bond
          defcontract withdrawal(account, amount) do
            @pre positive: amount > 0
          end
          @apply_contract :withdrawal
          @pre whole: amount == trunc(amount)
          def withdraw(acct, amt), do: %{acct | balance: acct.balance - amt}
        end
        """)

      assert mod.withdraw(%{balance: 100}, 30) == %{balance: 70}

      # The applied contract's own precondition still fires, attributed to the contract.
      contract_error =
        assert_raise Bond.PreconditionError, fn -> mod.withdraw(%{balance: 100}, -5) end

      assert Exception.message(contract_error) =~ "from contract :withdrawal"

      # The added precondition fires, attributed to the function (no "from contract").
      added_error =
        assert_raise Bond.PreconditionError, fn -> mod.withdraw(%{balance: 100}, 3.5) end

      refute Exception.message(added_error) =~ "from contract"
      assert Exception.message(added_error) =~ "Bond.NamedContractsTest.Extended.withdraw/2"
    end

    test "an added clause referencing a function param name (not canonical) is rejected" do
      assert_raise CompileError, ~r/not a contract argument/, fn ->
        compile!("""
        defmodule Bond.NamedContractsTest.AddedImplName do
          use Bond
          defcontract w(account, amount) do
            @pre amount > 0
          end
          @apply_contract :w
          @pre amt > 0
          def withdraw(acct, amt), do: acct
        end
        """)
      end
    end
  end

  describe "@apply_contract resolution diagnostics" do
    test "applying alongside behaviour inheritance is rejected" do
      compile!("""
      defmodule Bond.NamedContractsTest.Charger do
        use Bond.Behaviour
        @pre amount > 0
        @callback charge(amount :: integer) :: integer
      end
      """)

      assert_raise CompileError, ~r/both inherits a behaviour contract and applies/, fn ->
        compile!("""
        defmodule Bond.NamedContractsTest.Combined do
          use Bond, behaviours: [Bond.NamedContractsTest.Charger]
          defcontract cap(amount) do
            @pre amount < 1000
          end
          @apply_contract :cap
          @impl true
          def charge(amount), do: amount
        end
        """)
      end
    end

    test "an unknown contract lists the available name/arities" do
      assert_raise CompileError, ~r|no named contract foo/1.*available: bar/1|s, fn ->
        compile!("""
        defmodule Bond.NamedContractsTest.UnknownName do
          use Bond
          defcontract bar(x) do
            @pre x > 0
          end
          @apply_contract :foo
          def f(x), do: x
        end
        """)
      end
    end

    test "an arity mismatch is reported" do
      assert_raise CompileError, ~r|no named contract p/2.*available: p/1|s, fn ->
        compile!("""
        defmodule Bond.NamedContractsTest.ArityMismatch do
          use Bond
          defcontract p(x) do
            @pre x > 0
          end
          @apply_contract :p
          def f(a, b), do: a + b
        end
        """)
      end
    end

    test "a remote module with no named contracts is rejected" do
      assert_raise CompileError, ~r/defines no named contracts/, fn ->
        compile!("""
        defmodule Bond.NamedContractsTest.NotAContractModule do
          use Bond
          @apply_contract {Enum, :nope}
          def f(x), do: x
        end
        """)
      end
    end

    test "refining an applied contract is rejected in v1" do
      assert_raise CompileError, ~r/Refining a named contract is not supported/, fn ->
        compile!("""
        defmodule Bond.NamedContractsTest.RefineApplied do
          use Bond
          defcontract p(x) do
            @pre x > 0
          end
          @apply_contract :p
          @pre_weaken x == 0
          def f(x), do: x
        end
        """)
      end
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
      assert_raise CompileError, ~r/declares nothing/, fn ->
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
