defmodule Bond.Compiler.InvariantsTest do
  @moduledoc false

  use ExUnit.Case

  alias Bond.Compiler.Invariants

  describe "find_struct_arg/2" do
    test "returns {:ok, name} for `%__MODULE__{} = name` pattern" do
      params = quote(do: [%__MODULE__{} = stack, item])
      assert Invariants.find_struct_arg(params, []) == {:ok, :stack}
    end

    test "returns {:ok, name} for `name = %__MODULE__{}` (reversed) pattern" do
      params = quote(do: [stack = %__MODULE__{}, item])
      assert Invariants.find_struct_arg(params, []) == {:ok, :stack}
    end

    test "returns {:ok, name} for destructured-and-bound pattern" do
      params = quote(do: [%__MODULE__{field: x} = stack, item])
      assert Invariants.find_struct_arg(params, []) == {:ok, :stack}
    end

    test "returns {:warn, :unbound_destructure} for destructure without binding" do
      params = quote(do: [%__MODULE__{field: x}, item])
      assert Invariants.find_struct_arg(params, []) == {:warn, :unbound_destructure}
    end

    test "returns {:ok, name} for `is_struct(name, __MODULE__)` guard" do
      params = quote(do: [x, item])
      guards = quote(do: [is_struct(x, __MODULE__)])
      assert Invariants.find_struct_arg(params, guards) == {:ok, :x}
    end

    test "returns {:ok, name} for `is_struct/2` combined with `and`" do
      params = quote(do: [x, y])
      guards = quote(do: [is_struct(x, __MODULE__) and is_integer(y)])
      assert Invariants.find_struct_arg(params, guards) == {:ok, :x}
    end

    test "returns :none for a bare-variable function head" do
      params = quote(do: [x, item])
      assert Invariants.find_struct_arg(params, []) == :none
    end

    test "returns :none for an unrelated struct pattern" do
      params = quote(do: [%OtherMod{} = x])
      assert Invariants.find_struct_arg(params, []) == :none
    end

    test "returns :none for empty params" do
      assert Invariants.find_struct_arg([], []) == :none
    end
  end

  describe "resolve_mode/3" do
    test "purges when explicitly purged" do
      assert Invariants.resolve_mode(:purge, :def, some: :invariant) == :purge
    end

    test "purges for private functions" do
      assert Invariants.resolve_mode(true, :defp, some: :invariant) == :purge
    end

    test "purges when there are no invariants" do
      assert Invariants.resolve_mode(true, :def, []) == :purge
    end

    test "passes true/false through when invariants exist and function is public" do
      assert Invariants.resolve_mode(true, :def, [:x]) == true
      assert Invariants.resolve_mode(false, :def, [:x]) == false
    end
  end

  describe "pre_invariant_stmts/3" do
    test "returns [] when mode is :purge" do
      assert Invariants.pre_invariant_stmts(:any, :stack, :purge) == []
    end

    test "returns [] when struct_arg is nil" do
      assert Invariants.pre_invariant_stmts(:any, nil, true) == []
    end

    test "emits a should_evaluate? + evaluate_invariants block otherwise" do
      [ast] = Invariants.pre_invariant_stmts(:my_inv_fn, :stack, true)
      code = Macro.to_string(ast)
      assert code =~ ~r"Bond\.Runtime\.Eval\.should_evaluate\?\(:invariants, true\)"
      assert code =~ ~r"Bond\.Runtime\.Eval\.evaluate_invariants"
      assert code =~ ~r"my_inv_fn\(stack\)"
    end
  end

  describe "post_invariant_stmts/3" do
    test "returns [] when mode is :purge" do
      assert Invariants.post_invariant_stmts(:any, :purge, SomeMod) == []
    end

    test "emits a case extraction matching %Mod{} and {:ok, %Mod{}}" do
      [ast] = Invariants.post_invariant_stmts(:my_inv_fn, true, BoundedStack)
      code = Macro.to_string(ast)
      assert code =~ ~r"case var!\(result\)"
      assert code =~ ~r"%BoundedStack\{\}"
      assert code =~ ~r"\{:ok, %BoundedStack\{\}"
      assert code =~ ~r"my_inv_fn\(__bond_post_value__\)"
    end
  end
end
