defmodule Bond.UnderscoreBindingTest do
  @moduledoc """
  `= _name` head bindings that exist purely so a contract can reference the whole argument (#64).

  When a head destructures (`%{id: id} = api_spec`) and the body only uses the destructured
  fields, the `= api_spec` binding is there for the contract alone and Elixir warns that it is
  unused. Prefixing it (`= _api_spec`) is the idiomatic fix, and `Clauses.normalize_name/1`
  already treats `_api_spec` and `api_spec` as the same binding when negotiating canonical names
  across clauses — but the single-clause lifted defp reproduced the user's pattern verbatim, so
  the canonical name was never bound there and the contract failed to compile.
  """

  use ExUnit.Case, async: true

  describe "single-clause functions" do
    defmodule Single do
      @moduledoc false
      use Bond

      @pre big: spec.id > 100
      @post echoes: result == spec.id
      def get(%{id: id} = _spec), do: id

      @post wrong: result == spec.id
      def bad(%{id: _id} = _spec), do: :nope

      # Reversed match: `_spec = pattern`.
      @pre big: spec.id > 100
      def reversed(_spec = %{id: id}), do: id

      # The contract references a destructured name, not the whole argument, so the underscore
      # is left alone.
      @pre positive: id > 0
      def destructured_only(%{id: id} = _spec), do: id
    end

    test "a contract can reference the underscore-bound argument" do
      assert Single.get(%{id: 500}) == 500
    end

    test "the precondition reads that argument's real value" do
      error = assert_raise Bond.PreconditionError, fn -> Single.get(%{id: 5}) end
      assert error.label == :big
    end

    test "the postcondition reads it too" do
      error = assert_raise Bond.PostconditionError, fn -> Single.bad(%{id: 1}) end
      assert error.label == :wrong
    end

    test "works with the match reversed" do
      assert Single.reversed(%{id: 500}) == 500
      assert_raise Bond.PreconditionError, fn -> Single.reversed(%{id: 5}) end
    end

    test "destructured names remain available to contracts" do
      assert Single.destructured_only(%{id: 7}) == 7
      assert_raise Bond.PreconditionError, fn -> Single.destructured_only(%{id: 0}) end
    end
  end

  describe "multi-clause functions" do
    defmodule Multi do
      @moduledoc false
      use Bond

      @pre big: spec.id > 100
      @post echoes: result == spec.id
      def get(%{id: id} = _spec) when is_integer(id), do: id
      def get(%{id: id} = _spec), do: id
    end

    test "still resolve the canonical name across clauses" do
      assert Multi.get(%{id: 500}) == 500
    end

    test "still enforce the contract" do
      error = assert_raise Bond.PreconditionError, fn -> Multi.get(%{id: 5}) end
      assert error.label == :big
    end
  end

  describe "mixed underscore and plain names across clauses" do
    defmodule Mixed do
      @moduledoc false
      use Bond

      # `_spec` and `spec` normalise to the same canonical name, so the clauses agree.
      @pre big: spec.id > 100
      def get(%{id: id} = _spec) when is_integer(id), do: id
      def get(%{id: id} = spec), do: {id, spec.id}
    end

    test "the clauses agree rather than raising a name disagreement" do
      assert Mixed.get(%{id: 500}) == 500
    end

    test "the contract is enforced on the clause that uses the plain name" do
      assert_raise Bond.PreconditionError, fn -> Mixed.get(%{id: 5}) end
    end
  end

  describe "compile-time warnings" do
    test "an underscore-bound contract argument produces no unused-variable warning" do
      # BondTest.Diagnostics rather than a stderr capture: this module is async, and a
      # global capture picks up whatever any concurrently-compiling test emits (#86).
      warning =
        BondTest.Diagnostics.warnings("""
        defmodule BondTest.NoUnusedWarning do
          use Bond
          @pre big: spec.id > 100
          def get(%{id: id} = _spec), do: id
        end
        """)

      refute warning =~ "unused"
    end

    test "the un-prefixed form still warns, as plain Elixir would" do
      warning =
        BondTest.Diagnostics.warnings("""
        defmodule BondTest.StillWarns do
          use Bond
          @pre big: spec.id > 100
          def get(%{id: id} = spec), do: id
        end
        """)

      assert warning =~ ~s(variable "spec" is unused)
    end
  end
end
