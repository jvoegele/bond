defmodule Bond.PurgedAttributesTest do
  @moduledoc """
  #79 — a module attribute read only by a contract must not warn as unused once that
  contract is purged.

  Code that compiles cleanly in dev otherwise warns in prod, in exactly the build people
  gate on `--warnings-as-errors`, and the warning names Elixir rather than Bond, so it
  offers no route back to the cause.

  `async: false` and an env round-trip: these tests have to compile fixtures under a
  purging configuration, and `:bond`'s compile-time config is global. Bond's own suite
  runs with nothing purged, which is why this class of bug survived — the same gap that
  hid the StreamData warnings in #76.
  """

  use ExUnit.Case, async: false

  @kinds [:preconditions, :postconditions, :invariants, :checks]

  setup do
    previous = for k <- @kinds, do: {k, Application.get_env(:bond, k)}

    on_exit(fn ->
      for {k, v} <- previous do
        if is_nil(v), do: Application.delete_env(:bond, k), else: Application.put_env(:bond, k, v)
      end
    end)

    :ok
  end

  defp purge_everything do
    for k <- @kinds, do: Application.put_env(:bond, k, :purge)
  end

  defp unused_attribute_warnings(source) do
    source
    |> BondTest.Diagnostics.capture()
    |> Enum.filter(&(&1.message =~ "was set but never used"))
  end

  describe "an attribute read only by a purged contract" do
    setup do
      purge_everything()
      :ok
    end

    test "does not warn when read by @pre" do
      assert unused_attribute_warnings("""
             defmodule BondTest.PurgeScratch.Pre do
               use Bond
               @limit 10
               @pre within: n <= @limit
               def f(n), do: n
             end
             """) == []
    end

    test "does not warn when read by @post" do
      assert unused_attribute_warnings("""
             defmodule BondTest.PurgeScratch.Post do
               use Bond
               @limit 10
               @post within: result <= @limit
               def f(n), do: n
             end
             """) == []
    end

    test "does not warn when read by @invariant" do
      assert unused_attribute_warnings("""
             defmodule BondTest.PurgeScratch.Invariant do
               use Bond
               defstruct [:v]
               @limit 10
               @invariant within: subject.v <= @limit
               def f(%__MODULE__{} = s), do: s
             end
             """) == []
    end

    test "does not warn when read by check/1" do
      assert unused_attribute_warnings("""
             defmodule BondTest.PurgeScratch.Check do
               use Bond
               @limit 10
               def f(n) do
                 check within: n <= @limit
                 n
               end
             end
             """) == []
    end

    test "does not warn when read inside a where/whenever group" do
      assert unused_attribute_warnings("""
             defmodule BondTest.PurgeScratch.Group do
               use Bond
               @limit 10
               @post whenever({:ok, v} <- result), small: v <= @limit
               def f(n), do: {:ok, n}
             end
             """) == []
    end
  end

  describe "attributes that are genuinely unused" do
    test "still warn in a purging build" do
      purge_everything()

      assert [_] =
               unused_attribute_warnings("""
               defmodule BondTest.PurgeScratch.GenuinelyUnusedPurged do
                 use Bond
                 @unused 10
                 @pre within: n <= 5
                 def f(n), do: n
               end
               """)
    end

    test "still warn with contracts enabled" do
      assert [_] =
               unused_attribute_warnings("""
               defmodule BondTest.PurgeScratch.GenuinelyUnusedEnabled do
                 use Bond
                 @unused 10
                 @pre within: n <= 5
                 def f(n), do: n
               end
               """)
    end
  end

  describe "attribute_reads/1" do
    alias Bond.Compiler.PurgedAttributes

    test "finds reads, in source order, without duplicates" do
      ast = quote(do: n <= @limit and n >= @floor and n != @limit)
      assert PurgedAttributes.attribute_reads(ast) == [:limit, :floor]
    end

    test "ignores an attribute write" do
      # `@limit 10` carries its value as a single-element list, unlike a read.
      assert PurgedAttributes.attribute_reads(quote(do: @limit(10))) == []
    end

    test "ignores Bond's own bookkeeping attributes" do
      ast = quote(do: @__bond_contract_config__ && @bond_warn_skipped_invariants)
      assert PurgedAttributes.attribute_reads(ast) == []
    end
  end
end
