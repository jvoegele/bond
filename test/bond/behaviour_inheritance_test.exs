defmodule Bond.BehaviourInheritanceTest do
  use ExUnit.Case, async: true

  # --- Behaviours under test (the contract-declaring side) ---

  defmodule Ledger do
    use Bond.Behaviour

    @pre positive_amount: amount > 0
    @post non_negative: result >= 0
    @callback withdraw(balance :: non_neg_integer, amount :: pos_integer) :: non_neg_integer
  end

  defmodule Counter do
    use Bond.Behaviour

    @pre non_negative: n >= 0
    @callback label(n :: integer) :: String.t()
  end

  defmodule Greeter do
    use Bond.Behaviour

    @pre named: String.length(name) > 0
    @callback greet(name :: String.t()) :: String.t()

    @pre present: x != nil
    @callback optional_hook(x :: term) :: term
    @optional_callbacks optional_hook: 1
  end

  # --- Implementations (the contract-inheriting side) ---

  defmodule BankAccount do
    use Bond, behaviours: [Ledger]

    # Parameters deliberately named differently from the callback (bal/amt vs balance/amount)
    # to exercise positional rebind.
    @impl true
    def withdraw(bal, amt) when amt <= bal, do: bal - amt

    # A non-inherited function with its own contract — must keep working normally alongside
    # inherited ones.
    @pre at_least_two: x >= 2
    def double(x), do: x * 2
  end

  defmodule MultiClause do
    use Bond, behaviours: [Counter]

    @impl true
    def label(0), do: "zero"
    def label(n), do: "positive: #{n}"
  end

  defmodule Welcomer do
    use Bond, behaviours: [Greeter]

    # Implements only the required callback; the optional, contracted one is skipped.
    @impl true
    def greet(name), do: "Hello, #{name}!"
  end

  describe "inherited preconditions" do
    test "pass for valid arguments" do
      assert BankAccount.withdraw(100, 30) == 70
    end

    test "fail with attribution to the source behaviour and the impl MFA" do
      error =
        assert_raise Bond.PreconditionError, fn -> BankAccount.withdraw(100, 0) end

      assert error.source_behaviour == Ledger
      assert error.label == :positive_amount

      message = Exception.message(error)
      assert message =~ "precondition (inherited from Bond.BehaviourInheritanceTest.Ledger)"
      assert message =~ "BankAccount.withdraw/2"
    end
  end

  describe "inherited postconditions" do
    test "fail when the implementation breaks the promised result" do
      # amount > balance would yield a negative result, violating @post result >= 0. The impl's
      # own guard (amt <= bal) doesn't match here, so reach the inherited contract via a result
      # that the post rejects: withdraw more than the balance through a clause that allows it.
      defmodule Overdraft do
        use Bond, behaviours: [Ledger]

        @impl true
        def withdraw(balance, amount), do: balance - amount
      end

      error =
        assert_raise Bond.PostconditionError, fn -> Overdraft.withdraw(10, 50) end

      assert error.source_behaviour == Ledger
      assert error.label == :non_negative
      assert Exception.message(error) =~ "postcondition (inherited from"
    end
  end

  describe "positional rebind" do
    test "binds contract names to the impl's positions regardless of its parameter names" do
      # The contract references `amount`; the impl named that position `amt`. The violation
      # still fires, proving the rebind reached the right position.
      assert_raise Bond.PreconditionError, fn -> BankAccount.withdraw(100, -5) end
    end
  end

  describe "multi-clause implementations" do
    test "apply the inherited contract uniformly to every clause" do
      assert MultiClause.label(0) == "zero"
      assert MultiClause.label(3) == "positive: 3"
      assert_raise Bond.PreconditionError, fn -> MultiClause.label(-1) end
    end
  end

  describe "optional callbacks (sub-rule 3)" do
    test "are enforced only when the implementation defines them" do
      assert Welcomer.greet("Ada") == "Hello, Ada!"
      assert_raise Bond.PreconditionError, fn -> Welcomer.greet("") end
      refute function_exported?(Welcomer, :optional_hook, 1)
    end
  end

  describe "@impl independence (sub-rule 4)" do
    test "enforces contracts matched purely on {name, arity}, without @impl" do
      defmodule NoImplAttr do
        use Bond, behaviours: [Counter]

        # No `@impl true` here — matching is by {name, arity} only.
        def label(n), do: "n=#{n}"
      end

      assert NoImplAttr.label(2) == "n=2"
      assert_raise Bond.PreconditionError, fn -> NoImplAttr.label(-1) end
    end
  end

  describe "non-inherited functions coexist" do
    test "keep their own contracts in a module that inherits others" do
      assert BankAccount.double(3) == 6
      assert_raise Bond.PreconditionError, fn -> BankAccount.double(1) end
    end
  end

  def forward_telemetry(_event, _measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry, metadata})
  end

  describe "telemetry" do
    test "assertion-failure metadata carries the source behaviour" do
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:bond, :assertion, :failure],
        &__MODULE__.forward_telemetry/4,
        %{pid: self()}
      )

      assert_raise Bond.PreconditionError, fn -> BankAccount.withdraw(100, 0) end

      assert_received {:telemetry, metadata}
      assert metadata.source_behaviour == Ledger
      assert metadata.module == BankAccount

      :telemetry.detach(handler)
    end
  end

  describe "the immutable bright line" do
    test "impl @pre on an inherited operation is a compile error pointing at check/1" do
      assert_raise CompileError, ~r/may not declare its own.*check\/1/s, fn ->
        Code.compile_string("""
        defmodule Bond.BehaviourInheritanceTest.BrightLineViolator do
          use Bond, behaviours: [Bond.BehaviourInheritanceTest.Ledger]

          @impl true
          @pre amount > 100
          def withdraw(balance, amount), do: balance - amount
        end
        """)
      end
    end
  end

  describe "sub-rule 1: multiple behaviours, same {name, arity}" do
    defmodule LimiterA do
      use Bond.Behaviour
      @pre bounded: x <= 10
      @callback clamp(x :: integer) :: integer
    end

    defmodule LimiterB do
      use Bond.Behaviour
      @pre bounded: x <= 10
      @callback clamp(x :: integer) :: integer
    end

    test "structurally identical contracts from two behaviours are accepted" do
      defmodule DualLimiter do
        use Bond, behaviours: [LimiterA, LimiterB]

        @impl true
        def clamp(x), do: x
      end

      assert DualLimiter.clamp(5) == 5
      assert_raise Bond.PreconditionError, fn -> DualLimiter.clamp(11) end
    end

    test "conflicting contracts from two behaviours are a compile error located at the `use`" do
      error =
        assert_raise CompileError, ~r/conflicting inherited contracts/, fn ->
          Code.compile_string(
            """
            defmodule Bond.BehaviourInheritanceTest.ConflictBehaviourC do
              use Bond.Behaviour
              @pre bounded: x <= 5
              @callback clamp(x :: integer) :: integer
            end

            defmodule Bond.BehaviourInheritanceTest.Conflicted do
              use Bond, behaviours: [
                Bond.BehaviourInheritanceTest.LimiterA,
                Bond.BehaviourInheritanceTest.ConflictBehaviourC
              ]

              def clamp(x), do: x
            end
            """,
            "lib/conflicted.ex"
          )
        end

      assert error.file =~ "conflicted.ex"
      assert is_integer(error.line) and error.line > 0
    end
  end

  describe "sub-rule 2: behaviour without Bond contracts" do
    test "passing a plain (non-Bond) behaviour is a compile error located at the `use`" do
      error =
        assert_raise CompileError, ~r/does not use `Bond.Behaviour`/, fn ->
          Code.compile_string(
            """
            defmodule Bond.BehaviourInheritanceTest.PlainBehaviour do
              @callback run() :: :ok
            end

            defmodule Bond.BehaviourInheritanceTest.UsesPlain do
              use Bond, behaviours: [Bond.BehaviourInheritanceTest.PlainBehaviour]
              def run, do: :ok
            end
            """,
            "lib/uses_plain.ex"
          )
        end

      assert error.file =~ "uses_plain.ex"
      assert is_integer(error.line) and error.line > 0
    end
  end
end
