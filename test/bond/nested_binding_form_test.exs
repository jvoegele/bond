defmodule Bond.NestedBindingFormTest do
  @moduledoc """
  `where`/`whenever` inside a larger expression is a clear compile error, not `undefined
  variable` (#63).

  Composable binding forms were considered and declined: every motivating case is already
  expressible (see the "How do I bind names inside `~>` or `or`?" FAQ entry), and a nested form
  would have to fail differently from the top-level one to compose under `or`. The diagnostic
  points at the alternatives instead.
  """

  use ExUnit.Case, async: true

  defp compile(source) do
    Code.compile_string(source)
    :compiled
  rescue
    e in CompileError -> Exception.message(e)
  end

  describe "nested binding forms are rejected" do
    test "`where` inside an implication" do
      message =
        compile("""
        defmodule BondTest.NestedWhere do
          use Bond
          @post valid: result ~> where(%{"a" => a} = instr, a_ok: is_integer(a))
          def f(instr), do: is_map(instr)
        end
        """)

      assert message =~ "`where` may only appear at the start of a contract"
      assert message =~ "not inside a larger expression"
    end

    test "`whenever` inside an `or`" do
      message =
        compile("""
        defmodule BondTest.NestedWhenever do
          use Bond
          @post shape: match?({:ok, :done}, result) or whenever({:error, e} <- result, is_list(e))
          def f(x), do: x
        end
        """)

      assert message =~ "`whenever` may only appear at the start of a contract"
    end

    test "the message renders the offending form and names the alternatives" do
      message =
        compile("""
        defmodule BondTest.NestedWhereMessage do
          use Bond
          @post valid: result ~> where(%{"a" => a} = instr, a_ok: is_integer(a))
          def f(instr), do: is_map(instr)
        end
        """)

      assert message =~ ~s|where(%{"a" => a} = instr, a_ok: is_integer(a))|
      assert message =~ "match?/2"
      assert message =~ "private predicate function"
      assert message =~ "FAQ"
    end
  end

  describe "what the diagnostic must not catch" do
    test "an ordinary call to a user's own where/2 still compiles" do
      # `Ecto.Query.where/3` is the obvious real-world case. Recognition requires the binder
      # shape, so a call whose first argument is not `pattern = source` is left alone.
      assert compile("""
             defmodule BondTest.UserWhere do
               use Bond
               defp where(q, _kw), do: q
               @pre ok: where(:query, a: 1) == :query
               def f(x), do: x
             end
             """) == :compiled
    end

    test "top-level binding forms are unaffected" do
      assert compile("""
             defmodule BondTest.TopLevelBinding do
               use Bond
               @post where({:ok, n} = result), positive: n > 0
               def f(n), do: {:ok, n}
             end
             """) == :compiled
    end

    test "the all-inside top-level form is unaffected" do
      assert compile("""
             defmodule BondTest.AllInsideBinding do
               use Bond
               @post where({:ok, n} = result, positive: n > 0)
               def f(n), do: {:ok, n}
             end
             """) == :compiled
    end
  end

  describe "the documented alternatives actually work" do
    defmodule Alternatives do
      @moduledoc false
      use Bond

      # match?/2 with a guard
      @post shape:
              match?({:ok, :cleared}, result) or
                match?({:error, :validation_failed, errs} when is_list(errs), result)
      def run(x), do: x

      # two assertions, antecedent pushed into each scoped assertion
      @post shape: result ~> match?(%{"startFrame" => _, "endFrame" => _}, instr)
      @post whenever(%{"startFrame" => s, "endFrame" => e} <- instr),
        s_ok: result ~> (is_integer(s) and s >= 0),
        e_ok: result ~> (is_integer(e) and e > 0 and e != s)
      def valid?(instr), do: is_map(instr) and map_size(instr) > 0

      # a private predicate for a choice between shapes
      defp acceptable?({:ok, path}), do: String.starts_with?(path, "/")
      defp acceptable?({:error, :validation, errs}), do: Enum.all?(errs, &is_binary/1)
      defp acceptable?(_), do: false

      @post shape: acceptable?(result)
      def choose(x), do: x
    end

    test "match?/2 with a guard covers the disjunction-of-shapes case" do
      assert Alternatives.run({:ok, :cleared}) == {:ok, :cleared}

      assert Alternatives.run({:error, :validation_failed, []}) ==
               {:error, :validation_failed, []}

      assert_raise Bond.PostconditionError, fn ->
        Alternatives.run({:error, :validation_failed, :nope})
      end

      assert_raise Bond.PostconditionError, fn -> Alternatives.run({:ok, :other}) end
    end

    test "the two-assertion decomposition keeps its per-member labels" do
      assert Alternatives.valid?(%{"startFrame" => 0, "endFrame" => 5})

      error =
        assert_raise Bond.PostconditionError, fn ->
          Alternatives.valid?(%{"startFrame" => 3, "endFrame" => 3})
        end

      assert error.label == :e_ok
    end

    test "the two-assertion decomposition still requires the shape when the antecedent holds" do
      error =
        assert_raise Bond.PostconditionError, fn -> Alternatives.valid?(%{"other" => 1}) end

      assert error.label == :shape
    end

    test "the two-assertion decomposition is vacuous when the antecedent is false" do
      refute Alternatives.valid?(%{})
    end

    test "a private predicate covers alternatives needing their own bindings" do
      assert Alternatives.choose({:ok, "/abs"}) == {:ok, "/abs"}
      assert Alternatives.choose({:error, :validation, ["a"]}) == {:error, :validation, ["a"]}
      assert_raise Bond.PostconditionError, fn -> Alternatives.choose({:ok, "rel"}) end

      assert_raise Bond.PostconditionError, fn ->
        Alternatives.choose({:error, :validation, [1]})
      end
    end
  end
end
