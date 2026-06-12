defmodule Bond.Compiler.InheritedContractsTest do
  @moduledoc false

  use ExUnit.Case

  alias Bond.Compiler.Assertion
  alias Bond.Compiler.InheritedContracts
  alias Bond.Compiler.InheritedContracts.Context

  # The two flavours `Bond.Behaviour` and `Bond.Protocol` construct exactly these contexts; the
  # tests pin that the shared module reproduces each flavour's verbatim wording and semantics.
  @behaviour_ctx %Context{
    noun: "callback",
    contract_subject: "behaviour callback",
    reference_scope: "the callback's named arguments",
    pending_pre_key: :__bond_pending_pre__,
    pending_post_key: :__bond_pending_post__,
    stamp_source_behaviour: true,
    arg_naming_hint?: true
  }

  @protocol_ctx %Context{
    noun: "function",
    contract_subject: "protocol function",
    reference_scope: "its named arguments",
    pending_pre_key: :__bond_protocol_pending_pre__,
    pending_post_key: :__bond_protocol_pending_post__,
    reject_old: true
  }

  defp pre(expression), do: Assertion.new(:precondition, nil, expression, __ENV__)
  defp post(expression), do: Assertion.new(:postcondition, nil, expression, __ENV__)

  describe "unknown_reference_message/5" do
    test "behaviour flavour names the callback and appends the arg-naming hint" do
      message =
        InheritedContracts.unknown_reference_message(
          @behaviour_ctx,
          [:total],
          {:withdraw, 2},
          [:balance, :amount],
          "precondition"
        )

      assert message =~ "references `total`, which is not a callback argument"

      assert message =~
               "A contract on a behaviour callback may reference only the callback's named arguments"

      assert message =~ "the callback's argument names are `balance`, `amount`"
      assert message =~ "Name the callback's arguments (e.g. `@callback withdraw("
      assert message =~ "so contracts can bind to them positionally."
    end

    test "protocol flavour names the function and omits the arg-naming hint" do
      message =
        InheritedContracts.unknown_reference_message(
          @protocol_ctx,
          [:total],
          {:size, 1},
          [:data],
          "precondition"
        )

      assert message =~ "references `total`, which is not a function argument"
      assert message =~ "A contract on a protocol function may reference only its named arguments"
      assert message =~ "the function's argument names are `data`"
      refute message =~ "Name the callback's arguments"
      refute message =~ "positionally"
    end

    test "a postcondition mentions `result` as additionally referenceable" do
      message =
        InheritedContracts.unknown_reference_message(
          @protocol_ctx,
          [:total],
          {:size, 1},
          [:data],
          "postcondition"
        )

      assert message =~ "(and `result` for the return value)"
    end

    test "with no named arguments the phrase reflects that, per flavour" do
      behaviour =
        InheritedContracts.unknown_reference_message(
          @behaviour_ctx,
          [:x],
          {:f, 1},
          [:bond_arg_0],
          "precondition"
        )

      protocol =
        InheritedContracts.unknown_reference_message(
          @protocol_ctx,
          [:x],
          {:f, 1},
          [:bond_arg_0],
          "precondition"
        )

      assert behaviour =~ "the callback declares no named arguments"
      assert protocol =~ "the function declares no named arguments"
    end

    test "pluralizes the verb for multiple unknown names" do
      one =
        InheritedContracts.unknown_reference_message(
          @protocol_ctx,
          [:a],
          {:f, 1},
          [:data],
          "precondition"
        )

      many =
        InheritedContracts.unknown_reference_message(
          @protocol_ctx,
          [:a, :b],
          {:f, 1},
          [:data],
          "precondition"
        )

      assert one =~ "`a`, which is not"
      assert many =~ "`a`, `b`, which are not"
    end
  end

  describe "referenceable_names/1" do
    test "keeps genuinely named positions and drops generated bond_arg_ placeholders" do
      assert InheritedContracts.referenceable_names([:balance, :bond_arg_1, :amount]) ==
               MapSet.new([:balance, :amount])
    end
  end

  describe "generated_name?/1" do
    test "is true only for the bond_arg_ convention" do
      assert InheritedContracts.generated_name?(:bond_arg_0)
      refute InheritedContracts.generated_name?(:amount)
    end
  end

  describe "validate_referenced_names!/6" do
    test "passes when every referenced name is an argument (plus result in a post)" do
      assert :ok =
               InheritedContracts.validate_referenced_names!(
                 @behaviour_ctx,
                 [pre(quote(do: amount > 0))],
                 [post(quote(do: result >= balance - amount))],
                 {:withdraw, 2},
                 [:balance, :amount],
                 __ENV__
               )
    end

    test "raises a CompileError naming the unknown reference (behaviour wording)" do
      assert_raise CompileError, ~r/references `total`, which is not a callback argument/, fn ->
        InheritedContracts.validate_referenced_names!(
          @behaviour_ctx,
          [pre(quote(do: total > 0))],
          [],
          {:withdraw, 2},
          [:balance, :amount],
          __ENV__
        )
      end
    end

    test "raises a CompileError naming the unknown reference (protocol wording)" do
      assert_raise CompileError, ~r/references `total`, which is not a function argument/, fn ->
        InheritedContracts.validate_referenced_names!(
          @protocol_ctx,
          [pre(quote(do: total > 0))],
          [],
          {:size, 1},
          [:data],
          __ENV__
        )
      end
    end

    test "the CompileError line points at the offending assertion" do
      assertion = pre(quote(do: total > 0))

      error =
        assert_raise CompileError, fn ->
          InheritedContracts.validate_referenced_names!(
            @protocol_ctx,
            [assertion],
            [],
            {:size, 1},
            [:data],
            __ENV__
          )
        end

      assert error.line == assertion.definition_env.line
    end
  end

  describe "old/1 rejection (ctx.reject_old)" do
    test "the protocol flavour rejects old/1 in a postcondition" do
      assert_raise CompileError, ~r/uses `old\/1`, which is not supported/, fn ->
        InheritedContracts.validate_referenced_names!(
          @protocol_ctx,
          [],
          [post(quote(do: result > old(balance)))],
          {:withdraw, 1},
          [:balance],
          __ENV__
        )
      end
    end

    test "the behaviour flavour permits old/1 in a postcondition" do
      assert :ok =
               InheritedContracts.validate_referenced_names!(
                 @behaviour_ctx,
                 [],
                 [post(quote(do: result > old(balance)))],
                 {:withdraw, 1},
                 [:balance],
                 __ENV__
               )
    end
  end
end
