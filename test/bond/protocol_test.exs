defmodule Bond.ProtocolTest do
  use ExUnit.Case, async: false

  # --- Protocols and (deliberately Bond-unaware) implementations ---

  defprotocol Sized do
    use Bond.Protocol

    @post non_negative: result >= 0
    @spec size(t) :: integer()
    def size(data)
  end

  defmodule Boxed do
    defstruct items: []
  end

  defmodule Negative do
    defstruct []
  end

  defimpl Sized, for: Boxed do
    def size(%Boxed{items: items}), do: length(items)
  end

  # An impl that breaks the protocol's promise, to exercise postcondition failure.
  defimpl Sized, for: Negative do
    def size(%Negative{}), do: -1
  end

  defprotocol Bounded do
    use Bond.Protocol

    @pre in_range: limit >= 0
    @spec clamp(t, integer()) :: integer()
    def clamp(data, limit)
  end

  defmodule Counter do
    defstruct n: 0
  end

  defimpl Bounded, for: Counter do
    # Ordinary impl — different param names than the protocol's `data`/`limit`.
    def clamp(%Counter{n: n}, max), do: min(n, max)
  end

  defprotocol Describable do
    use Bond.Protocol

    @fallback_to_any true
    @post nonempty: byte_size(result) > 0
    def describe(data)
  end

  defimpl Describable, for: Any do
    def describe(_), do: "anything"
  end

  defimpl Describable, for: Boxed do
    def describe(%Boxed{items: items}), do: "boxed(#{length(items)})"
  end

  defmodule Blank do
    defstruct []
  end

  # A fallback-eligible impl that violates the @post, to prove failures are caught there too.
  defimpl Describable, for: Blank do
    def describe(_), do: ""
  end

  setup do
    # Contracts default to enabled; make sure no prior test left a runtime override in the
    # global persistent_term modes term.
    Bond.Config.reset()
    :ok
  end

  describe "inherited postconditions (Option B dispatch wrap)" do
    test "pass when the implementation honours the contract" do
      assert Sized.size(%Boxed{items: [:a, :b, :c]}) == 3
    end

    test "fail when an implementation breaks the promised result" do
      error = assert_raise Bond.PostconditionError, fn -> Sized.size(%Negative{}) end

      assert error.source_protocol == Sized
      assert error.impl == Sized.impl_for(%Negative{})
      assert error.label == :non_negative

      message = Exception.message(error)
      assert message =~ "postcondition (from protocol Bond.ProtocolTest.Sized"
      assert message =~ "impl #{inspect(Sized.impl_for(%Negative{}))}"
      assert message =~ "Bond.ProtocolTest.Sized.size/1"
    end
  end

  describe "inherited preconditions" do
    test "pass for valid arguments, regardless of the impl's own parameter names" do
      assert Bounded.clamp(%Counter{n: 10}, 5) == 5
    end

    test "fail with attribution to the protocol and resolved impl" do
      error = assert_raise Bond.PreconditionError, fn -> Bounded.clamp(%Counter{n: 1}, -1) end

      assert error.source_protocol == Bounded
      assert error.impl == Bounded.impl_for(%Counter{n: 1})
      assert Exception.message(error) =~ "precondition (from protocol Bond.ProtocolTest.Bounded"
    end
  end

  describe "fallback_to_any" do
    test "wraps both concrete impls and the Any fallback" do
      assert Describable.describe(%Boxed{items: [1, 2]}) == "boxed(2)"
      assert Describable.describe(:an_atom) == "anything"
    end

    test "a fallback impl that violates the contract is still caught" do
      error = assert_raise Bond.PostconditionError, fn -> Describable.describe(%Blank{}) end
      assert error.source_protocol == Describable
      assert error.impl == Describable.impl_for(%Blank{})
    end
  end

  describe "implementations need zero Bond awareness" do
    test "a plain defimpl is enforced at dispatch" do
      # Boxed's impl does not use Bond in any way, yet Sized.size/1 is contracted.
      refute function_exported?(Sized.Boxed, :__bond_contracts__, 0)
      assert Sized.size(%Boxed{items: []}) == 0
    end
  end

  describe "telemetry" do
    def forward(_event, _measurements, metadata, %{pid: pid}),
      do: send(pid, {:telemetry, metadata})

    test "assertion-failure metadata carries the protocol and resolved impl" do
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(handler, [:bond, :assertion, :failure], &__MODULE__.forward/4, %{
        pid: self()
      })

      assert_raise Bond.PostconditionError, fn -> Sized.size(%Negative{}) end

      assert_received {:telemetry, metadata}
      assert metadata.source_protocol == Sized
      assert metadata.impl == Sized.impl_for(%Negative{})
      assert metadata.kind == :postcondition

      :telemetry.detach(handler)
    end
  end

  describe "compile-time validation" do
    test "a contract referencing a name the function doesn't declare is a compile error" do
      assert_raise CompileError, ~r/references `total`, which is not a function argument/, fn ->
        Code.compile_string("""
        defprotocol Bond.ProtocolTest.BadRef do
          use Bond.Protocol
          @pre positive: total > 0
          def withdraw(account, amount)
        end
        """)
      end
    end

    test "`result` is rejected in a precondition but allowed in a postcondition" do
      assert_raise CompileError, ~r/references `result`/, fn ->
        Code.compile_string("""
        defprotocol Bond.ProtocolTest.ResultInPre do
          use Bond.Protocol
          @pre result > 0
          def f(data)
        end
        """)
      end
    end

    test "`old/1` in a protocol postcondition is a clear compile error (v1 non-goal)" do
      assert_raise CompileError, ~r/uses `old\/1`, which is not supported in protocol/, fn ->
        Code.compile_string("""
        defprotocol Bond.ProtocolTest.UsesOld do
          use Bond.Protocol
          @post result == old(data)
          def echo(data)
        end
        """)
      end
    end

    test "@pre/@post not preceding a def is a compile error" do
      assert_raise CompileError, ~r/do not precede a protocol `def`/, fn ->
        Code.compile_string("""
        defprotocol Bond.ProtocolTest.Dangling do
          use Bond.Protocol
          def f(data)
          @post result > 0
        end
        """)
      end
    end
  end

  describe "consolidation" do
    # `BondTest.Counted` lives in test/support so it compiles to an on-disk beam that
    # `Protocol.consolidate/2` can read (test-file modules compile in-memory and have none).
    alias BondTest.Counted
    alias BondTest.Counted.{Bag, Broken}

    test "contracts still enforce after the protocol is consolidated" do
      # `mix compile` consolidates app protocols, so the support fixture arrives consolidated;
      # re-consolidating is idempotent and keeps the test self-contained on its own artifacts.
      {:ok, binary} = Protocol.consolidate(Counted, [Bag, Broken])
      path = :code.which(Counted)
      :code.purge(Counted)
      :code.delete(Counted)
      {:module, Counted} = :code.load_binary(Counted, path, binary)

      assert Protocol.consolidated?(Counted)
      assert Counted.count(%Bag{contents: [:x, :y]}) == 2

      error = assert_raise Bond.PostconditionError, fn -> Counted.count(%Broken{}) end
      assert error.source_protocol == Counted
      assert error.impl == Counted.impl_for(%Broken{})
    end
  end
end
