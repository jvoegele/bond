defmodule Bond.PropertyTest.ProbeContractFixtures do
  @moduledoc false

  defmodule Account do
    @moduledoc false
    use Bond

    # Two literal-comparison preconditions on `amount` (index 0) → boundary candidates
    # [-1, 0, 1, 99, 100, 101]; the postcondition holds for every *valid* amount.
    @pre amount >= 0
    @pre amount <= 100
    @post result >= 1
    def deposit_fee(amount), do: amount + 1
  end

  defmodule NoContract do
    @moduledoc false
    use Bond
    def identity(x), do: x
  end
end

defmodule Bond.PropertyTest.ProbeContractTest do
  @moduledoc """
  Tests for `Bond.PropertyTest.probe_contract/2`, the boundary-driven single-function shape.

  Mirrors the `contract_holds` test strategy: a real passing property (regression guard), plus
  direct tests of the runtime helpers (`__boundaries__/3`, `__augment_generators__/2`,
  `__satisfies_pre__/4`) the macro expands into, plus a macro-expansion shape test.
  """

  use ExUnit.Case
  use Bond.PropertyTest

  alias Bond.PropertyTest
  alias Bond.PropertyTest.ProbeContractFixtures.Account
  alias Bond.PropertyTest.ProbeContractFixtures.NoContract

  describe "probe_contract &Mod.fun/N (passing property)" do
    # Base generator straddles the valid range so the filter discards out-of-range draws while the
    # mixed-in boundary candidates probe the edges (0 and 100). The postcondition is the oracle.
    probe_contract(&Account.deposit_fee/1, args: [StreamData.integer(-5..105)])
  end

  describe "__boundaries__/3" do
    test "returns the per-arg boundary candidates for a contracted function" do
      assert PropertyTest.__boundaries__(Account, :deposit_fee, 1) ==
               %{0 => [-1, 0, 1, 99, 100, 101]}
    end

    test "returns an empty map for a module with no boundaries reflection" do
      assert PropertyTest.__boundaries__(NoContract, :identity, 1) == %{}
    end

    test "returns an empty map for an unknown function on a boundaries-emitting module" do
      assert PropertyTest.__boundaries__(Account, :nope, 9) == %{}
    end
  end

  describe "__satisfies_pre__/4" do
    test "is true for inputs that satisfy the precondition, including boundaries" do
      assert PropertyTest.__satisfies_pre__(Account, :deposit_fee, 1, [0])
      assert PropertyTest.__satisfies_pre__(Account, :deposit_fee, 1, [100])
      assert PropertyTest.__satisfies_pre__(Account, :deposit_fee, 1, [50])
    end

    test "is false for inputs that violate the precondition" do
      refute PropertyTest.__satisfies_pre__(Account, :deposit_fee, 1, [-1])
      refute PropertyTest.__satisfies_pre__(Account, :deposit_fee, 1, [101])
    end

    test "is true when the module exports no precondition shim (nothing to filter)" do
      assert PropertyTest.__satisfies_pre__(NoContract, :identity, 1, [:anything])
    end
  end

  describe "__augment_generators__/2" do
    test "leaves generators without candidates untouched" do
      gen = StreamData.integer(1..3)
      assert [^gen] = PropertyTest.__augment_generators__([gen], %{})
    end

    test "blends boundary candidates into the indexed argument's generator" do
      # The base generator can only produce 1000; any other value sampled must be an injected
      # boundary candidate, proving the candidates are actually mixed in.
      candidates = [0, 100]

      augmented =
        PropertyTest.__augment_generators__([StreamData.constant(1000)], %{0 => candidates})

      sampled =
        augmented
        |> hd()
        |> Enum.take(200)
        |> Enum.uniq()
        |> Enum.sort()

      # Both the base value and the injected boundaries should appear over 200 draws.
      assert 1000 in sampled
      assert Enum.any?(candidates, &(&1 in sampled))
      assert Enum.all?(sampled, &(&1 in [1000 | candidates]))
    end
  end

  describe "underlying mechanism (filter discards out-of-precondition draws)" do
    test "every draw passing the filter satisfies the precondition" do
      boundaries = PropertyTest.__boundaries__(Account, :deposit_fee, 1)
      [gen] = PropertyTest.__augment_generators__([StreamData.integer(-20..120)], boundaries)

      gen
      |> Enum.take(300)
      |> Enum.each(fn amount ->
        if PropertyTest.__satisfies_pre__(Account, :deposit_fee, 1, [amount]) do
          assert amount >= 0 and amount <= 100
        end
      end)
    end
  end

  describe "macro expansion shape" do
    test "expands to a property block that filters by the precondition and applies the function" do
      ast =
        quote do
          probe_contract(&Account.deposit_fee/1, args: [StreamData.integer()])
        end

      expanded = ast |> Macro.expand_once(__ENV__) |> Macro.to_string()

      assert expanded =~ ~r"property\b"
      assert expanded =~ ~r"check\(?\s*all\(?\s*args <- StreamData\.fixed_list"
      assert expanded =~ "__satisfies_pre__"
      assert expanded =~ ~r"apply\("
    end

    test "raises ArgumentError when :args option is missing" do
      assert_raise ArgumentError, fn ->
        Code.eval_quoted(
          quote do
            require Bond.PropertyTest
            Bond.PropertyTest.probe_contract(&Account.deposit_fee/1, [])
          end
        )
      end
    end

    test "raises ArgumentError for a non-remote-capture argument" do
      assert_raise ArgumentError, fn ->
        Code.eval_quoted(
          quote do
            require Bond.PropertyTest
            Bond.PropertyTest.probe_contract(:not_a_capture, args: [])
          end
        )
      end
    end
  end
end
