defmodule Bond.PropertyTest.Form2Test do
  @moduledoc """
  Tests for `Bond.PropertyTest.contract_holds/2` in its module-sequence (Form 2) shape.

  Same three-angle structure as the Form 1 tests:

    1. **Passing-property tests** — drive `BondTest.InvariantSmoke` through
       `contract_holds` with constructors/transformers/observers that respect its
       invariants. These run as real properties.

    2. **Underlying-mechanism tests** — confirm that a hand-built sequence containing a
       deliberately invariant-violating operation does raise `Bond.InvariantError` when
       passed to `Sequence.run/2`. The macro builds on the same runner, so if that's
       solid the macro's failure path is too.

    3. **Macro-expansion test** — verifies the expansion shape and the required-option
       check.
  """

  use ExUnit.Case
  use Bond.PropertyTest

  alias Bond.PropertyTest.Sequence
  alias BondTest.InvariantSmoke

  describe "contract_holds Module (passing properties)" do
    contract_holds(InvariantSmoke,
      constructors: [{:new, [StreamData.integer(0..50)]}],
      transformers: [{:push, [StreamData.term()]}],
      observers: [{:capacity, []}]
    )

    contract_holds(InvariantSmoke,
      constructors: [
        {:new, [StreamData.integer(0..50)]},
        {:try_new, [StreamData.integer(0..50)]}
      ],
      transformers: [{:push, [StreamData.term()]}],
      name: "InvariantSmoke holds invariants under random sequences with mixed constructors"
    )
  end

  describe "underlying mechanism (Sequence.run propagates contract violations)" do
    test "a sequence containing broken_push raises Bond.InvariantError" do
      sequence =
        {{:constructor, :new, [2]},
         [
           {:transformer, :push, [:a]},
           {:transformer, :broken_push, [:b]}
         ]}

      assert_raise Bond.InvariantError, fn ->
        Sequence.run(InvariantSmoke, sequence)
      end
    end
  end

  describe "macro expansion shape" do
    test "expands to a property block invoking Sequence.generator + Sequence.run" do
      ast =
        quote do
          contract_holds(InvariantSmoke,
            constructors: [{:new, [StreamData.integer(0..50)]}],
            transformers: [{:push, [StreamData.term()]}]
          )
        end

      expanded =
        Macro.expand_once(ast, __ENV__)
        |> Macro.to_string()

      assert expanded =~ ~r"property\b"
      assert expanded =~ ~r"Bond\.PropertyTest\.Sequence\.generator"
      assert expanded =~ ~r"Bond\.PropertyTest\.Sequence\.run"
    end

    test "raises ArgumentError when :constructors is missing" do
      assert_raise ArgumentError, ~r/constructors/, fn ->
        Code.eval_quoted(
          quote do
            require Bond.PropertyTest
            Bond.PropertyTest.contract_holds(InvariantSmoke, transformers: [])
          end
        )
      end
    end

    test "raises ArgumentError when :constructors is empty" do
      assert_raise ArgumentError, ~r/constructors/, fn ->
        Code.eval_quoted(
          quote do
            require Bond.PropertyTest
            Bond.PropertyTest.contract_holds(InvariantSmoke, constructors: [])
          end
        )
      end
    end
  end
end
