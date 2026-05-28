defmodule Bond.AttrCompatTest do
  @moduledoc """
  Verifies that Bond's `Kernel.@/1` override correctly forwards standard Elixir
  module attributes without dropping or mangling them.

  Bond's `use Bond` macro does `import Kernel, except: [@: 1]` then `import Bond`,
  placing Bond's specific `@pre`/`@post`/`@invariant`/`@doc` clauses plus a
  catch-all `defmacro @attr` (which forwards to `Kernel.@/1`) in scope. Any
  attribute Bond does not recognise must survive the round-trip intact.

  Each fixture module in `BondTest.AttrCompat.*` also includes at least one `@pre`
  or `@post` contract, confirming that attribute forwarding and Bond's own
  interception coexist correctly in the same module.

  Fixture source: `test/support/bond_test/attr_compat.ex`.
  """

  use ExUnit.Case

  describe "@derive" do
    test "derived Inspect implementation is applied — only declared fields are shown" do
      s = %BondTest.AttrCompat.DeriveInspect{n: 42, secret: :hidden}
      inspected = inspect(s)
      assert inspected =~ "n: 42"
      refute inspected =~ "secret"
    end

    test "@pre contracts still fire in a module using @derive" do
      assert_raise Bond.PreconditionError, fn ->
        BondTest.AttrCompat.DeriveInspect.new(-1)
      end
    end
  end

  describe "@enforce_keys" do
    test "@enforce_keys is respected — creating a struct with a missing key raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        struct!(BondTest.AttrCompat.EnforceKeys, %{})
      end
    end

    test "struct creation with the required key present succeeds" do
      assert %BondTest.AttrCompat.EnforceKeys{name: "Alice"} =
               BondTest.AttrCompat.EnforceKeys.new("Alice")
    end

    test "@pre contracts still fire in a module using @enforce_keys" do
      assert_raise Bond.PreconditionError, fn ->
        BondTest.AttrCompat.EnforceKeys.new(123)
      end
    end
  end

  describe "typespecs (@spec, @type, @typep, @opaque)" do
    test "@spec is stored in the compiled module's typespec information" do
      {:ok, specs} = Code.Typespec.fetch_specs(BondTest.AttrCompat.Typespecs)
      spec_funs = Enum.map(specs, fn {{name, arity}, _} -> {name, arity} end)
      assert {:double, 1} in spec_funs
    end

    test "@type public type is present in the compiled module's type information" do
      {:ok, types} = Code.Typespec.fetch_types(BondTest.AttrCompat.Typespecs)
      tagged = Enum.map(types, fn {kind, {name, _, _}} -> {kind, name} end)
      assert {:type, :count} in tagged
    end

    # @typep private types are stripped from the BEAM's exported type chunk and are
    # not returned by Code.Typespec.fetch_types/1. Forwarding is verified by compilation:
    # the module compiles cleanly and get_key/1 (which calls a defp with an internal_key()
    # spec) executes correctly.
    test "@typep is forwarded — function using a @typep-typed defp executes correctly" do
      assert "key_7" = BondTest.AttrCompat.Typespecs.get_key(7)
    end

    test "@opaque type is present and tagged :opaque in the compiled module's type information" do
      {:ok, types} = Code.Typespec.fetch_types(BondTest.AttrCompat.Typespecs)
      tagged = Enum.map(types, fn {kind, {name, _, _}} -> {kind, name} end)
      assert {:opaque, :token} in tagged
    end

    test "@pre contracts still fire in a module using typespecs" do
      assert_raise Bond.PreconditionError, fn ->
        BondTest.AttrCompat.Typespecs.double("not an integer")
      end
    end
  end

  describe "@callback and @behaviour" do
    test "@callback is forwarded — BehaviourDef exposes the declared callback via behaviour_info/1" do
      callbacks = BondTest.AttrCompat.BehaviourDef.behaviour_info(:callbacks)
      assert {:transform, 1} in callbacks
    end

    test "@behaviour is forwarded — BehaviourImpl attributes list its declared behaviour" do
      behaviours = BondTest.AttrCompat.BehaviourImpl.__info__(:attributes)[:behaviour]
      assert BondTest.AttrCompat.BehaviourDef in behaviours
    end

    test "@impl is forwarded — BehaviourImpl.transform/1 executes normally" do
      assert {BondTest.AttrCompat.BehaviourImpl, :hello} =
               BondTest.AttrCompat.BehaviourImpl.transform(:hello)
    end

    test "@pre contracts still fire in a module using @behaviour and @impl" do
      assert_raise Bond.PreconditionError, fn ->
        BondTest.AttrCompat.BehaviourImpl.transform(nil)
      end
    end
  end

  describe "accumulating custom attributes" do
    test "all accumulated values are present" do
      rules = BondTest.AttrCompat.AccumulatingAttr.rules()
      assert :rule_a in rules
      assert :rule_b in rules
      assert :rule_c in rules
      assert length(rules) == 3
    end

    test "@pre contracts still fire in a module using accumulating attributes" do
      assert_raise Bond.PreconditionError, fn ->
        BondTest.AttrCompat.AccumulatingAttr.count("not a list")
      end
    end
  end

  describe "@external_resource" do
    test "@external_resource is tracked in the compiled module's attributes" do
      attrs = BondTest.AttrCompat.ExternalResource.__info__(:attributes)
      assert Keyword.has_key?(attrs, :external_resource)
    end

    test "@pre contracts still fire in a module using @external_resource" do
      assert_raise Bond.PreconditionError, fn ->
        BondTest.AttrCompat.ExternalResource.echo(-1)
      end
    end
  end
end
