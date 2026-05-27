defmodule Bond.Compiler.InvariantsTest do
  @moduledoc false

  use ExUnit.Case

  alias Bond.Compiler.Invariants

  describe "detect_struct_params/2" do
    test "detects `%__MODULE__{} = name` at position 0" do
      params = quote(do: [%__MODULE__{} = stack, item])
      assert Invariants.detect_struct_params(params, []) == [{:bound, :stack, 0}]
    end

    test "detects reversed `name = %__MODULE__{}` pattern" do
      params = quote(do: [stack = %__MODULE__{}, item])
      assert Invariants.detect_struct_params(params, []) == [{:bound, :stack, 0}]
    end

    test "detects destructure-and-bind `%__MODULE__{field: x} = name`" do
      params = quote(do: [%__MODULE__{field: x} = stack, item])
      assert Invariants.detect_struct_params(params, []) == [{:bound, :stack, 0}]
    end

    test "detects struct at a non-zero parameter position" do
      params = quote(do: [item, %__MODULE__{} = stack])
      assert Invariants.detect_struct_params(params, []) == [{:bound, :stack, 1}]
    end

    test "detects destructure-only `%__MODULE__{...}` without binding" do
      params = quote(do: [%__MODULE__{items: [h | _]}, item])
      assert Invariants.detect_struct_params(params, []) == [{:destructure, 0}]
    end

    test "detects bare `name` plus `is_struct(name, __MODULE__)` guard" do
      params = quote(do: [x, item])
      guards = quote(do: [is_struct(x, __MODULE__)])
      assert Invariants.detect_struct_params(params, guards) == [{:bound, :x, 0}]
    end

    test "detects is_struct inside left side of compound `and` guard" do
      params = quote(do: [x, y])
      guards = quote(do: [is_struct(x, __MODULE__) and is_integer(y)])
      assert Invariants.detect_struct_params(params, guards) == [{:bound, :x, 0}]
    end

    test "detects is_struct inside right side of compound `and` guard" do
      params = quote(do: [x, y])
      guards = quote(do: [is_integer(y) and is_struct(x, __MODULE__)])
      assert Invariants.detect_struct_params(params, guards) == [{:bound, :x, 0}]
    end

    test "detects is_struct inside `or` guard" do
      params = quote(do: [x])
      guards = quote(do: [is_atom(x) or is_struct(x, __MODULE__)])
      assert Invariants.detect_struct_params(params, guards) == [{:bound, :x, 0}]
    end

    test "detects is_struct nested inside `and` inside `or`" do
      params = quote(do: [x, y])
      guards = quote(do: [is_nil(y) or (is_integer(y) and is_struct(x, __MODULE__))])
      assert Invariants.detect_struct_params(params, guards) == [{:bound, :x, 0}]
    end

    test "detects is_struct across multiple `when ... when ...` guards" do
      params = quote(do: [x])
      guards = quote(do: [is_atom(x), is_struct(x, __MODULE__)])
      assert Invariants.detect_struct_params(params, guards) == [{:bound, :x, 0}]
    end

    test "returns multiple entries for `def merge(%__MODULE__{} = a, %__MODULE__{} = b)`" do
      params = quote(do: [%__MODULE__{} = a, %__MODULE__{} = b])

      assert Invariants.detect_struct_params(params, []) ==
               [{:bound, :a, 0}, {:bound, :b, 1}]
    end

    test "mixes bound and destructure entries in parameter order" do
      params = quote(do: [%__MODULE__{} = a, %__MODULE__{field: x}])

      assert Invariants.detect_struct_params(params, []) ==
               [{:bound, :a, 0}, {:destructure, 1}]
    end

    test "returns [] for a bare-variable head with no relevant guard" do
      params = quote(do: [x, item])
      assert Invariants.detect_struct_params(params, []) == []
    end

    test "returns [] when guard mentions an unrelated module" do
      params = quote(do: [x])
      guards = quote(do: [is_struct(x, OtherMod)])
      assert Invariants.detect_struct_params(params, guards) == []
    end

    test "returns [] for an unrelated struct pattern" do
      params = quote(do: [%OtherMod{} = x])
      assert Invariants.detect_struct_params(params, []) == []
    end

    test "returns [] for empty params" do
      assert Invariants.detect_struct_params([], []) == []
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

  describe "all_pre_invariant_stmts/5" do
    test "returns [] when mode is :purge" do
      assert Invariants.all_pre_invariant_stmts(
               :any,
               [{:bound, :stack, 0}],
               :purge,
               true,
               true
             ) == []
    end

    test "returns [] when struct_params is empty" do
      assert Invariants.all_pre_invariant_stmts(:any, [], true, true, true) == []
    end

    test "emits one should_evaluate? + evaluate_invariants block per bound param" do
      [ast] =
        Invariants.all_pre_invariant_stmts(
          :my_inv_fn,
          [{:bound, :stack, 0}],
          true,
          true,
          true
        )

      code = Macro.to_string(ast)
      assert code =~ ~r"Bond\.Runtime\.Eval\.should_evaluate\?\(\s*:invariants,\s*true"
      assert code =~ ~r"Bond\.Runtime\.Eval\.evaluate_invariants"
      assert code =~ ~r"my_inv_fn\(stack\)"
    end

    test "emits separate statements for multi-struct heads, in parameter order" do
      stmts =
        Invariants.all_pre_invariant_stmts(
          :my_inv_fn,
          [{:bound, :a, 0}, {:bound, :b, 1}],
          true,
          true,
          true
        )

      assert length(stmts) == 2
      [first, second] = stmts
      assert Macro.to_string(first) =~ ~r"my_inv_fn\(a\)"
      assert Macro.to_string(second) =~ ~r"my_inv_fn\(b\)"
    end

    test "uses __bond_subject_<idx>__ for destructure entries" do
      [ast] =
        Invariants.all_pre_invariant_stmts(
          :my_inv_fn,
          [{:destructure, 0}],
          true,
          true,
          true
        )

      assert Macro.to_string(ast) =~ ~r"my_inv_fn\(__bond_subject_0__\)"
    end
  end

  describe "post_invariant_stmts/5" do
    test "returns [] when mode is :purge" do
      assert Invariants.post_invariant_stmts(:any, :purge, SomeMod, true, true) == []
    end

    test "delegates the struct-shape match to Bond.Runtime.Eval.check_struct_invariant" do
      [ast] = Invariants.post_invariant_stmts(:my_inv_fn, true, BoundedStack, true, true)
      code = Macro.to_string(ast)
      assert code =~ ~r"Bond\.Runtime\.Eval\.check_struct_invariant"
      assert code =~ ~r"var!\(result\)"
      assert code =~ ~r"BoundedStack"
      assert code =~ ~r"my_inv_fn\(__bond_post_value__\)"
      assert code =~ ~r"should_evaluate\?\(:invariants"
      # The %Mod{} / {:ok, %Mod{}} match no longer lives in the using module — it moved
      # into Bond.Runtime.Eval so Elixir's type checker can't flag the speculative struct
      # clauses as unreachable for functions returning other shapes.
      refute code =~ ~r"case var!\(result\)"
    end
  end
end
