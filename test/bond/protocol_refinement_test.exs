defmodule Bond.ProtocolRefinementTest do
  use ExUnit.Case, async: false

  # Eiffel-style refinement of inherited protocol contracts (#16 Phase B):
  #   @pre_weaken      => effective pre  = inherited OR  weaken      (require else)
  #   @post_strengthen => effective post = inherited AND strengthen  (ensure then)
  # Refinement expressions reference the PROTOCOL's canonical argument names.
  # Bond.Protocol.Impl is strictly opt-in; plain defimpl blocks are completely unaffected.

  # --- Protocol: precondition only ---

  defprotocol Bounded do
    use Bond.Protocol

    @pre in_range: limit >= 0
    def clamp(data, limit)
  end

  defmodule Counter do
    defstruct n: 0
  end

  defmodule FlexCounter do
    defstruct n: 0
  end

  defmodule PostCounter do
    defstruct n: 0
  end

  defimpl Bounded, for: Counter do
    # Plain impl — no Bond.Protocol.Impl, no refinement.
    def clamp(%Counter{n: n}, limit), do: min(n, limit)
  end

  defimpl Bounded, for: FlexCounter do
    use Bond.Protocol.Impl

    # Accepts the protocol's contract (limit >= 0) OR the weakened alternative (limit == -1).
    @pre_weaken neg_one_ok: limit == -1
    def clamp(%FlexCounter{n: n}, -1), do: n
    def clamp(%FlexCounter{n: n}, limit), do: min(n, limit)
  end

  defimpl Bounded, for: PostCounter do
    use Bond.Protocol.Impl

    # Protocol has no postcondition; @post_strengthen adds one.
    @post_strengthen non_negative: result >= 0
    def clamp(%PostCounter{n: n}, limit), do: min(n, limit)
  end

  # --- Protocol: both precondition and postcondition ---

  defprotocol Account do
    use Bond.Protocol

    @pre positive_amount: amount > 0
    @post non_negative: result >= 0
    def withdraw(data, amount)
  end

  defmodule Savings do
    defstruct balance: 0
  end

  defmodule FreeSavings do
    defstruct balance: 0
  end

  defmodule AllSavings do
    defstruct balance: 0
  end

  defimpl Account, for: Savings do
    # Plain impl: inherits both pre and post verbatim.
    def withdraw(%Savings{balance: b}, amount), do: b - amount
  end

  defimpl Account, for: FreeSavings do
    use Bond.Protocol.Impl

    @pre_weaken zero_ok: amount == 0
    def withdraw(%FreeSavings{balance: b}, amount), do: b - amount
  end

  defimpl Account, for: AllSavings do
    use Bond.Protocol.Impl

    # Both weakening and strengthening on the same function.
    @pre_weaken zero_ok: amount == 0
    @post_strengthen even_result: rem(result, 2) == 0
    def withdraw(%AllSavings{balance: b}, amount), do: b - amount
  end

  setup do
    Bond.Config.reset()
    :ok
  end

  describe "non-refining impls are unaffected" do
    test "a plain defimpl without Bond.Protocol.Impl is enforced at dispatch, unchanged" do
      assert Bounded.clamp(%Counter{n: 10}, 5) == 5
      refute function_exported?(Bounded.Counter, :__bond_effective_pre__clamp_2__, 2)
      refute function_exported?(Bounded.Counter, :__bond_effective_post__clamp_2__, 3)
    end

    test "the inherited precondition still rejects invalid args for plain impls" do
      error = assert_raise Bond.PreconditionError, fn -> Bounded.clamp(%Counter{n: 5}, -1) end
      assert error.source_protocol == Bounded
      assert error.impl == Bounded.impl_for(%Counter{})
    end

    test "a plain defimpl with both pre and post inherits them verbatim" do
      assert Account.withdraw(%Savings{balance: 100}, 30) == 70
      refute function_exported?(Account.Savings, :__bond_effective_pre__withdraw_2__, 2)
      refute function_exported?(Account.Savings, :__bond_effective_post__withdraw_2__, 3)
    end
  end

  describe "precondition weakening (@pre_weaken)" do
    test "passes when the inherited precondition holds" do
      # limit == 5, limit >= 0 holds, canonical name 'limit' from protocol.
      assert Bounded.clamp(%FlexCounter{n: 10}, 5) == 5
    end

    test "passes when the inherited precondition fails but the weakening alternative holds" do
      # limit == -1 fails limit >= 0, but FlexCounter weakened it to also accept -1.
      assert Bounded.clamp(%FlexCounter{n: 10}, -1) == 10
    end

    test "fails when neither the inherited nor the weakening precondition holds" do
      error = assert_raise Bond.PreconditionError, fn -> Bounded.clamp(%FlexCounter{n: 5}, -2) end

      assert error.source_protocol == Bounded
      assert error.impl == Bounded.impl_for(%FlexCounter{})
      assert error.label == :refined_precondition

      message = Exception.message(error)
      assert message =~ "precondition (from protocol Bond.ProtocolRefinementTest.Bounded"
      assert message =~ "impl #{inspect(Bounded.impl_for(%FlexCounter{}))}"
      # The rendered assertion shows both folded halves.
      assert message =~ "(limit >= 0) or (limit == -1)"
    end

    test "the combined failure carries the weakening group's binding" do
      error = assert_raise Bond.PreconditionError, fn -> Bounded.clamp(%FlexCounter{n: 5}, -2) end
      assert error.binding[:limit] == -2
    end

    test "the refining impl exports the effective-pre function" do
      assert function_exported?(
               Bounded.impl_for(%FlexCounter{}),
               :__bond_effective_pre__clamp_2__,
               2
             )
    end
  end

  describe "postcondition strengthening (@post_strengthen)" do
    test "passes when both the inherited and strengthening postconditions hold" do
      assert Account.withdraw(%AllSavings{balance: 100}, 30) == 70
    end

    test "fails when the strengthening clause fails even though the inherited holds" do
      # 69 is non-negative (inherited holds) but not even (strengthening fails).
      error =
        assert_raise Bond.PostconditionError, fn ->
          Account.withdraw(%AllSavings{balance: 100}, 31)
        end

      assert error.source_protocol == Account
      assert error.impl == Account.impl_for(%AllSavings{})
      assert error.label == :even_result
    end

    test "still enforces the inherited postcondition" do
      # -40 violates the inherited non_negative post.
      error =
        assert_raise Bond.PostconditionError, fn ->
          Account.withdraw(%AllSavings{balance: 10}, 50)
        end

      assert error.source_protocol == Account
      assert error.impl == Account.impl_for(%AllSavings{})
      assert error.label == :non_negative
    end

    test "the refining impl exports the effective-post function" do
      assert function_exported?(
               Account.impl_for(%AllSavings{}),
               :__bond_effective_post__withdraw_2__,
               3
             )
    end
  end

  describe "weakening and strengthening together" do
    test "both refinements apply on the same function" do
      # Inherited pre holds, inherited post holds, even result.
      assert Account.withdraw(%AllSavings{balance: 100}, 30) == 70
      # Weakened pre lets amount == 0 through; 100 is even.
      assert Account.withdraw(%AllSavings{balance: 100}, 0) == 100
      # Strengthening rejects an odd result.
      assert_raise Bond.PostconditionError, fn ->
        Account.withdraw(%AllSavings{balance: 100}, 31)
      end

      # Weakened pre still rejects a genuinely invalid call.
      assert_raise Bond.PreconditionError, fn ->
        Account.withdraw(%AllSavings{balance: 100}, -5)
      end
    end
  end

  describe "@post_strengthen when the protocol declares no postcondition" do
    test "adds a postcondition where the protocol declared none" do
      # Protocol Bounded has no @post; PostCounter adds one via @post_strengthen.
      assert Bounded.clamp(%PostCounter{n: 5}, 10) == 5
    end

    test "the added postcondition is enforced at dispatch" do
      # PostCounter n: -1 would return min(-1, 5) == -1, violating the strengthen non_negative.
      error =
        assert_raise Bond.PostconditionError, fn ->
          Bounded.clamp(%PostCounter{n: -1}, 5)
        end

      assert error.source_protocol == Bounded
      assert error.impl == Bounded.impl_for(%PostCounter{})
      assert error.label == :non_negative
    end
  end

  describe "telemetry from effective pre/post" do
    def forward(_event, _measurements, metadata, %{pid: pid}),
      do: send(pid, {:telemetry, metadata})

    test "assertion-failure metadata carries the protocol and resolved impl (pre_weaken)" do
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(handler, [:bond, :assertion, :failure], &__MODULE__.forward/4, %{
        pid: self()
      })

      assert_raise Bond.PreconditionError, fn -> Bounded.clamp(%FlexCounter{n: 5}, -2) end

      assert_received {:telemetry, metadata}
      assert metadata.source_protocol == Bounded
      assert metadata.impl == Bounded.impl_for(%FlexCounter{})
      assert metadata.kind == :precondition

      :telemetry.detach(handler)
    end

    test "assertion-failure metadata carries the protocol and resolved impl (post_strengthen)" do
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(handler, [:bond, :assertion, :failure], &__MODULE__.forward/4, %{
        pid: self()
      })

      assert_raise Bond.PostconditionError, fn ->
        Account.withdraw(%AllSavings{balance: 100}, 31)
      end

      assert_received {:telemetry, metadata}
      assert metadata.source_protocol == Account
      assert metadata.impl == Account.impl_for(%AllSavings{})
      assert metadata.kind == :postcondition

      :telemetry.detach(handler)
    end
  end

  describe "compile-time errors" do
    test "Bond.Protocol.Impl in a non-Bond.Protocol protocol raises a clear error" do
      assert_raise CompileError,
                   ~r/does not use Bond\.Protocol/,
                   fn ->
                     Code.compile_string("""
                     defprotocol Bond.ProtocolRefinementTest.PlainProto do
                       def f(data)
                     end

                     defimpl Bond.ProtocolRefinementTest.PlainProto, for: Atom do
                       use Bond.Protocol.Impl
                       @pre_weaken data == nil
                       def f(data), do: data
                     end
                     """)
                   end
    end

    test "@pre_weaken with no inherited precondition (protocol has only @post) errors" do
      assert_raise CompileError,
                   ~r/no precondition to weaken|nothing to weaken/,
                   fn ->
                     Code.compile_string("""
                     defprotocol Bond.ProtocolRefinementTest.PostOnlyProto do
                       use Bond.Protocol
                       @post non_negative: result >= 0
                       def size(data)
                     end

                     defimpl Bond.ProtocolRefinementTest.PostOnlyProto, for: Atom do
                       use Bond.Protocol.Impl
                       @pre_weaken data == nil
                       def size(data), do: 0
                     end
                     """)
                   end
    end

    test "@pre_weaken/@post_strengthen on a function with no contract in the protocol errors" do
      assert_raise CompileError,
                   ~r/declares no Bond contract/,
                   fn ->
                     Code.compile_string("""
                     defprotocol Bond.ProtocolRefinementTest.PartialProto do
                       use Bond.Protocol
                       @post non_negative: result >= 0
                       def count(data)
                       def name(data)
                     end

                     defimpl Bond.ProtocolRefinementTest.PartialProto, for: Atom do
                       use Bond.Protocol.Impl
                       @post_strengthen nonempty: String.length(result) > 0
                       def name(data), do: to_string(data)
                       def count(_), do: 0
                     end
                     """)
                   end
    end

    test "old/1 in @pre_weaken is a clear compile error" do
      assert_raise CompileError,
                   ~r/uses `old\/1`/,
                   fn ->
                     Code.compile_string("""
                     defimpl Bond.ProtocolRefinementTest.Bounded, for: Integer do
                       use Bond.Protocol.Impl
                       @pre_weaken limit == old(limit)
                       def clamp(data, limit), do: min(data, limit)
                     end
                     """)
                   end
    end

    test "dangling @pre_weaken with no def in the module is a compile error" do
      assert_raise CompileError,
                   ~r/@pre_weaken\/@post_strengthen.*do not precede a `def`/,
                   fn ->
                     Code.compile_string("""
                     defimpl Bond.ProtocolRefinementTest.Bounded, for: Float do
                       use Bond.Protocol.Impl
                       @pre_weaken limit == -1
                     end
                     """)
                   end
    end

    test "@pre_weaken referencing a name not in the protocol's canonical args errors" do
      assert_raise CompileError,
                   ~r/references `unknown`, which is not/,
                   fn ->
                     Code.compile_string("""
                     defimpl Bond.ProtocolRefinementTest.Bounded, for: BitString do
                       use Bond.Protocol.Impl
                       @pre_weaken unknown == 0
                       def clamp(data, limit), do: min(byte_size(data), limit)
                     end
                     """)
                   end
    end
  end

  describe "direct-call bypass (documented limitation)" do
    test "calling a concrete impl directly bypasses the dispatch wrapper and its contract" do
      # Direct call to the impl module skips the protocol wrapper entirely.
      # limit=-999 fails all preconditions through the protocol, but the raw impl
      # returns the arithmetic result unchecked. Only calls through Bounded.clamp/2 are guarded.
      impl = Bounded.impl_for(%FlexCounter{})
      assert apply(impl, :clamp, [%FlexCounter{n: 10}, -999]) == -999
    end
  end
end
