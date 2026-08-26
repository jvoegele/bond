defmodule Bond.DeclarativeDefInteropTest do
  @moduledoc """
  Composing with a library that overrides `def`/`defp` and rewrites arity-1 heads.

  Regression tests for #134, where a `@post` on an arity-1 function in a `Phoenix.Component`
  module failed to compile with a `MatchError` on `{:__bond_postconditions__<fun>__1, 2}`.
  `BondTest.DeclarativeDef` reproduces the mechanism without the dependency.
  """

  use ExUnit.Case, async: true

  alias BondTest.DeclarativeDef

  describe "a module whose def/defp are overridden and rewrite arity-1 heads" do
    test "compiles a @post on an arity-1 defp — the shape that raised in #134" do
      defmodule PostOnArityOne do
        use DeclarativeDef
        use Bond

        @post unchanged: is_map(result)
        defp stop_connecting(socket), do: socket

        def call(socket), do: stop_connecting(socket)
      end

      assert PostOnArityOne.call(%{a: 1}) == %{a: 1}
    end

    test "the contract is live, not merely compiled" do
      defmodule PostFiresOnArityOne do
        use DeclarativeDef
        use Bond

        @post a_map: is_map(result)
        def normalize(socket), do: socket
      end

      assert PostFiresOnArityOne.normalize(%{}) == %{}

      assert_raise Bond.PostconditionError, fn ->
        PostFiresOnArityOne.normalize(:not_a_map)
      end
    end

    test "@pre and @post together on an arity-1 function" do
      defmodule PreAndPostOnArityOne do
        use DeclarativeDef
        use Bond

        @pre a_map: is_map(socket)
        @post a_map: is_map(result)
        def touch(socket), do: socket
      end

      assert PreAndPostOnArityOne.touch(%{}) == %{}
      assert_raise Bond.PreconditionError, fn -> PreAndPostOnArityOne.touch(:nope) end
    end

    test "arities the override leaves alone still work" do
      defmodule OtherArities do
        use DeclarativeDef
        use Bond

        @post a_list: is_list(result)
        def zero, do: []

        @post a_map: is_map(result)
        def two(socket, _item), do: socket

        @post a_map: is_map(result)
        def three(_a, _b, socket), do: socket
      end

      assert OtherArities.zero() == []
      assert OtherArities.two(%{}, 1) == %{}
      assert OtherArities.three(1, 2, %{}) == %{}
    end

    test "a destructuring arity-1 head still binds its names for the contract" do
      defmodule DestructuringArityOne do
        use DeclarativeDef
        use Bond

        @post preserved: result == id
        def id_of(%{id: id}), do: id
      end

      assert DestructuringArityOne.id_of(%{id: 7}) == 7
    end

    test "a doc set by the library, not the user, does not collide with Bond's (#136)" do
      # `Phoenix.Component` documents a component from its `attr` declarations. Bond then appends
      # its `#### Postconditions` section by re-emitting `@doc`, and the two collided: Bond's
      # bodiless-head mitigation (#71) was gated on Bond having seen the user write a `@doc`, and
      # a doc set by another library is not one it has any record of.
      warnings =
        BondTest.Diagnostics.warnings("""
        defmodule LibraryDocumented do
          use BondTest.DeclarativeDef
          use Bond

          BondTest.DeclarativeDef.documented_by_the_library("A badge.")

          @post a_map: is_map(result)
          def badge(assigns), do: assigns
        end
        """)

      refute warnings =~ "redefining @doc"

      # `apply/3` because the module is defined by compiling a string, so the compiler has no way
      # to know it exists and would warn on a direct call.
      assert apply(LibraryDocumented, :badge, [%{}]) == %{}
    end

    test "the foreign macro expands once per user function, never inside generated code" do
      Process.delete(DeclarativeDef)

      defmodule ExpansionSites do
        use DeclarativeDef
        use Bond

        @post a_map: is_map(result)
        def only_function(socket), do: socket
      end

      sites = DeclarativeDef.expansions()

      # Once, for the user's own definition. Bond emits its wrapper and its lifted
      # `__bond_postconditions__only_function__1/2` via `Kernel.def`/`Kernel.defp` and strips the
      # captured call, so neither carries a copy. Re-running it would duplicate whatever
      # registration the real library performs — Phoenix's duplicates a component's attr docs.
      assert sites == [{:only_function, 1}]

      refute Enum.any?(sites, fn {name, _arity} ->
               name |> Atom.to_string() |> String.starts_with?("__bond_")
             end)
    end
  end
end
