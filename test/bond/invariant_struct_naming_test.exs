defmodule Bond.InvariantStructNamingTest do
  @moduledoc """
  Regression tests for #93: the invariant *entry* check was only emitted when the
  function head named the struct as the literal `__MODULE__`. Spelling the module out
  — `def f(%MyApp.Cart{} = cart)`, the same thing in every respect — silently skipped
  it, and also escaped `:warn_skipped_invariants`, because that warning's heuristic
  resolved names head detection did not.

  Every spelling that resolves to the module must behave identically, and one that
  resolves elsewhere must not be mistaken for it. The fixture bodies are inert, so a
  raise can only have come from the entry check.
  """

  use ExUnit.Case, async: true

  alias BondTest.StructNaming

  # Already violates `within: length(items) <= capacity`, so any function with a
  # working entry check must reject it.
  defp invalid, do: %StructNaming{items: [:a, :b, :c], capacity: 1}
  defp valid, do: %StructNaming{items: [:a], capacity: 3}

  describe "entry check fires however the struct is named in the head" do
    for fun <- [
          :via_module_pattern,
          :via_qualified_pattern,
          :via_module_guard,
          :via_qualified_guard,
          :via_module_destructure,
          :via_qualified_destructure
        ] do
      test "#{fun}/1 rejects a struct that violates the invariant" do
        assert_raise Bond.InvariantError, fn ->
          apply(StructNaming, unquote(fun), [invalid()])
        end
      end

      test "#{fun}/1 accepts a valid struct" do
        assert apply(StructNaming, unquote(fun), [valid()]) == :ok
      end
    end
  end

  describe "a single-segment module, where the bare name is the module" do
    test "%Single{} in the head is detected" do
      assert_raise Bond.InvariantError, fn -> Single.via_bare_name(%Single{count: -1}) end
      assert Single.via_bare_name(%Single{count: 1}) == :ok
    end

    test "is_struct(s, Single) in the guard is detected" do
      assert_raise Bond.InvariantError, fn -> Single.via_bare_name_guard(%Single{count: -1}) end
      assert Single.via_bare_name_guard(%Single{count: 1}) == :ok
    end
  end

  describe "an explicit alias to the module itself resolves" do
    alias BondTest.StructNaming.SelfAliased

    test "%Cart{} where `alias __MODULE__, as: Cart` is in scope" do
      assert_raise Bond.InvariantError, fn ->
        SelfAliased.via_self_alias(%SelfAliased{items: [:a, :b], capacity: 1})
      end

      assert SelfAliased.via_self_alias(%SelfAliased{items: [:a], capacity: 3}) == :ok
    end

    test "is_struct(s, Cart) where the alias is in scope" do
      assert_raise Bond.InvariantError, fn ->
        SelfAliased.via_self_alias_guard(%SelfAliased{items: [:a, :b], capacity: 1})
      end
    end
  end

  describe "a different module's struct is not mistaken for this one" do
    test "an alias pointing elsewhere gets no entry check" do
      # `alias BondTest.StructNaming.Other, as: Cart` — so `%Cart{}` in the head is a
      # foreign struct. Binding `subject` to it would evaluate `subject.capacity` on a
      # struct that has no such key.
      assert BondTest.StructNaming.ForeignAlias.touch(%StructNaming.Other{count: -5}) == :ok
    end

    test "a head matching an unrelated struct gets no entry check" do
      # If `%Other{}` were treated as `Unrelated`'s own struct, `subject` would bind
      # to it and `subject.count >= 0` would evaluate against the wrong value.
      assert StructNaming.Unrelated.touch(%StructNaming.Other{count: -5}) == :ok
    end
  end
end
