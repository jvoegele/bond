defmodule Bond.FailurePathContractsTest do
  @moduledoc """
  Contracts over the failure path, for failures modelled as values (#33).

  Bond has no exception contract, deliberately — see the "Can I write a contract for the failure
  path?" FAQ entry. These tests pin the patterns that entry documents, so the guidance cannot
  quietly stop working.
  """

  use ExUnit.Case, async: true

  defmodule Bank do
    @moduledoc false
    use Bond

    @known_errors [:insufficient, :frozen, :unknown_account]

    # The `signals_only` equivalent: constrain the set of failures the function may produce.
    @post only_known_errors:
            match?({:ok, _}, result) or
              match?({:error, r} when r in [:insufficient, :frozen, :unknown_account], result)
    def withdraw(balance, amount) when amount > balance, do: {:error, :insufficient}
    def withdraw(_balance, _amount), do: {:ok, :debited}

    @post only_known_errors:
            match?({:ok, _}, result) or
              match?({:error, r} when r in [:insufficient, :frozen, :unknown_account], result)
    def leaky(_balance, _amount), do: {:error, :typo_nobody_declared}

    # The conditional `signals` equivalent: what must hold *when* a particular failure occurs.
    @post whenever({:error, :insufficient} <- result),
      untouched: ledger_total() == old(ledger_total())
    def audited_withdraw(balance, amount) when amount > balance, do: {:error, :insufficient}
    def audited_withdraw(_balance, _amount), do: {:ok, :debited}

    def known_errors, do: @known_errors

    defp ledger_total, do: 42
  end

  describe "constraining the set of failures (the signals_only equivalent)" do
    test "a success passes" do
      assert Bank.withdraw(100, 10) == {:ok, :debited}
    end

    test "a declared failure passes" do
      assert Bank.withdraw(10, 100) == {:error, :insufficient}
    end

    test "an undeclared failure violates the postcondition" do
      error = assert_raise Bond.PostconditionError, fn -> Bank.leaky(10, 100) end

      assert error.label == :only_known_errors
    end
  end

  describe "asserting on a particular failure (the conditional signals equivalent)" do
    test "the scoped assertion runs on the matching failure" do
      assert Bank.audited_withdraw(10, 100) == {:error, :insufficient}
    end

    test "and is vacuous on success" do
      assert Bank.audited_withdraw(100, 10) == {:ok, :debited}
    end
  end

  describe "why exceptions are out of scope" do
    defmodule Account do
      @moduledoc false
      use Bond
      defstruct balance: 0

      @invariant non_negative: subject.balance >= 0

      @pre positive: amount > 0
      @post debited: result.balance == old(account.balance) - amount
      def withdraw(%__MODULE__{} = account, amount) do
        if amount > account.balance, do: raise(ArgumentError, "insufficient")
        %{account | balance: account.balance - amount}
      end
    end

    test "the caller's value is unchanged after a raise — immutability, not a contract" do
      account = struct!(Account, balance: 100)

      assert_raise ArgumentError, fn -> Account.withdraw(account, 250) end

      # This is why `account.balance == old(account.balance)` on the failure path cannot fail:
      # nothing the callee does can rebind the caller's value.
      assert account.balance == 100
    end

    test "the original exception propagates unwrapped, with @post never evaluated" do
      account = struct!(Account, balance: 100)

      # Bond adds no failure-path machinery, so the exception a caller sees is exactly the one
      # the function raised — no wrapping, no change of type between purged and unpurged builds.
      assert_raise ArgumentError, "insufficient", fn -> Account.withdraw(account, 250) end
    end

    test "preconditions still guard the call that would fail" do
      account = struct!(Account, balance: 100)

      error = assert_raise Bond.PreconditionError, fn -> Account.withdraw(account, -5) end

      assert error.label == :positive
    end
  end
end
