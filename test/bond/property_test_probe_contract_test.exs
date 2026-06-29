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

  defmodule SizedList do
    @moduledoc false
    use Bond

    # A size-wrapper precondition (#43): boundary probes are `{:size, :length, n}` for n in 2..4,
    # so `probe_contract` constructs lists of those lengths from the base generator and the filter
    # discards over-long lists. The postcondition is the length-preserving oracle.
    @pre length(items) <= 3
    @post length(result) == length(items)
    def trim(items), do: Enum.reverse(items)
  end

  defmodule Impossible do
    @moduledoc false
    use Bond

    # An unsatisfiable precondition: no generated input survives the filter, so `probe_contract`
    # exhausts StreamData's discard budget — used to exercise the FilterTooRestrictiveError path.
    @pre x > 0 and x < 0
    def echo(x), do: x
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
  alias Bond.PropertyTest.ProbeContractFixtures.Impossible
  alias Bond.PropertyTest.ProbeContractFixtures.NoContract
  alias Bond.PropertyTest.ProbeContractFixtures.SizedList

  describe "probe_contract &Mod.fun/N (passing property)" do
    # Base generator straddles the valid range so the filter discards out-of-range draws while the
    # mixed-in boundary candidates probe the edges (0 and 100). The postcondition is the oracle.
    probe_contract(&Account.deposit_fee/1, args: [StreamData.integer(-5..105)])

    # Size-wrapper boundaries (#43): the base generator produces lists up to length 5, so the filter
    # discards the over-long ones while the constructed length-2/3/4 collections probe the edge.
    probe_contract(&SizedList.trim/1,
      args: [StreamData.list_of(StreamData.integer(), max_length: 5)]
    )
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

    test "constructs collections of the target size for {:size, ...} probes (#43)" do
      # The base generator only ever produces a 6-element list, so any other length sampled must be
      # a constructed boundary collection, proving the size probes resize the base output.
      base = StreamData.constant([:a, :b, :c, :d, :e, :f])
      probes = [{:size, :length, 2}, {:size, :length, 3}, {:size, :length, 4}]

      [augmented] = PropertyTest.__augment_generators__([base], %{0 => probes})

      lengths =
        augmented
        |> Enum.take(200)
        |> Enum.map(&length/1)
        |> Enum.uniq()
        |> Enum.sort()

      assert 6 in lengths
      assert Enum.any?([2, 3, 4], &(&1 in lengths))
      assert Enum.all?(lengths, &(&1 in [2, 3, 4, 6]))
    end
  end

  describe "__resize__/3 (size-boundary construction, #43)" do
    test "lists: truncates when too long, pads by cycling when too short, reuses elements" do
      assert PropertyTest.__resize__(:length, [1, 2, 3, 4], 2) == [1, 2]
      assert PropertyTest.__resize__(:length, [1, 2], 2) == [1, 2]
      assert PropertyTest.__resize__(:length, [1, 2], 5) == [1, 2, 1, 2, 1]
    end

    test "an empty list can't be padded — left unchanged for the @pre filter to discard" do
      assert PropertyTest.__resize__(:length, [], 3) == []
      assert PropertyTest.__resize__(:length, [], 0) == []
    end

    test "binaries: truncate and pad to a target byte size" do
      assert PropertyTest.__resize__(:byte_size, "hello", 3) == "hel"
      assert PropertyTest.__resize__(:byte_size, "ab", 5) == "ababa"
      assert PropertyTest.__resize__(:byte_size, "", 4) == ""
      assert byte_size(PropertyTest.__resize__(:byte_size, "xyz", 4)) == 4
    end

    test "tuples: resized via their element list" do
      assert PropertyTest.__resize__(:tuple_size, {1, 2, 3, 4}, 2) == {1, 2}
      assert PropertyTest.__resize__(:tuple_size, {1, 2}, 4) == {1, 2, 1, 2}
    end

    test "maps shrink only — an undersized map is left unchanged" do
      m = %{a: 1, b: 2, c: 3}
      assert map_size(PropertyTest.__resize__(:map_size, m, 2)) == 2
      assert PropertyTest.__resize__(:map_size, %{a: 1}, 3) == %{a: 1}
    end

    test "a value the wrapper doesn't match is left unchanged (filtered by @pre)" do
      assert PropertyTest.__resize__(:length, "not a list", 2) == "not a list"
      assert PropertyTest.__resize__(:map_size, %URI{}, 1) == %URI{}
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

    test "wraps the generation in a rescue that converts StreamData's filter-exhaustion error (#43)" do
      ast =
        quote do
          probe_contract(&Account.deposit_fee/1, args: [StreamData.integer()])
        end

      expanded = ast |> Macro.expand_once(__ENV__) |> Macro.to_string()

      assert expanded =~ "StreamData.FilterTooNarrowError"
      assert expanded =~ "__reraise_too_restrictive__"
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

  describe "FilterTooRestrictiveError (over-restrictive precondition, #43)" do
    test "the underlying filter genuinely exhausts for an unsatisfiable precondition" do
      # No input satisfies Impossible.echo/1's `@pre`, so StreamData's filter gives up — this is the
      # raw error `probe_contract` rescues and reshapes. (Driven via Enum, which seeds itself, since
      # `check all` requires a `property` context.)
      filtered =
        StreamData.filter(StreamData.integer(), fn x ->
          PropertyTest.__satisfies_pre__(Impossible, :echo, 1, [x])
        end)

      assert_raise StreamData.FilterTooNarrowError, fn -> Enum.take(filtered, 1) end
    end

    test "__reraise_too_restrictive__ reshapes it into a Bond error naming the function" do
      narrow = %StreamData.FilterTooNarrowError{last_generated_value: {:value, 7}}

      error =
        assert_raise Bond.PropertyTest.FilterTooRestrictiveError, fn ->
          PropertyTest.__reraise_too_restrictive__(narrow, Account, :deposit_fee, 1, [])
        end

      message = Exception.message(error)
      assert message =~ "Account.deposit_fee/1"
      assert message =~ "StreamData.bind/2"
      assert message =~ "Last generated value: 7"
    end

    test "the message omits the last-value hint when StreamData captured none" do
      narrow = %StreamData.FilterTooNarrowError{last_generated_value: :none}

      error =
        assert_raise Bond.PropertyTest.FilterTooRestrictiveError, fn ->
          PropertyTest.__reraise_too_restrictive__(narrow, Account, :deposit_fee, 1, [])
        end

      refute Exception.message(error) =~ "Last generated value"
    end
  end
end
