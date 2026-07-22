defmodule Bond.InterpolatedDocsTest do
  @moduledoc """
  `@doc` values that are not literals (#70).

  Bond's `@doc` override buffers the attribute as unexpanded AST and replays it at
  `@before_compile`. An interpolated heredoc arrives as `{:<<>>, _, _}` AST, which has to be
  evaluated when it is re-emitted — escaping it hands raw AST to `Module.put_attribute/3`, which
  rejects it outright.

  The fixture lives in `test/support` because `Code.fetch_docs/1` needs an on-disk beam.
  """

  use ExUnit.Case, async: true

  alias BondTest.InterpolatedDocs

  defp fun_doc(fun, arity) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(InterpolatedDocs)

    Enum.find_value(docs, fn
      {{:function, ^fun, ^arity}, _, _, doc, _} -> doc
      _ -> nil
    end)
  end

  defp doc_text(fun, arity) do
    case fun_doc(fun, arity) do
      %{"en" => text} -> text
      other -> other
    end
  end

  describe "interpolated @doc on a contracted function" do
    test "evaluates the interpolation rather than emitting its AST" do
      doc = doc_text(:new, 1)

      # `#{__MODULE__}` interpolates via `to_string/1`, hence the `Elixir.` prefix — plain Elixir
      # semantics, unchanged by Bond.
      assert doc =~ "Builds a %Elixir.BondTest.InterpolatedDocs{} measured in widgets."
      refute doc =~ "<<>>"
      refute doc =~ "to_string"
    end

    test "appends the generated contract sections to the interpolated text" do
      doc = doc_text(:new, 1)

      assert doc =~ "#### Preconditions"
      assert doc =~ "pos: x > 0"
      assert doc =~ "#### Postconditions"
      assert doc =~ "ok: result.x == x"
    end

    test "keeps the user's prose ahead of the contract sections" do
      doc = doc_text(:new, 1)

      [prose, _contracts] = String.split(doc, "#### Preconditions", parts: 2)

      assert prose =~ "Builds a %Elixir.BondTest.InterpolatedDocs{}"
    end

    test "emits a single @doc, not one per source" do
      # Both halves land in one attribute; a second `Module.put_attribute(:doc, …)` would
      # overwrite the first, silently dropping either the prose or the contract sections.
      doc = doc_text(:new, 1)

      assert doc =~ "Builds a %Elixir.BondTest.InterpolatedDocs{}"
      assert doc =~ "#### Preconditions"
    end
  end

  describe "other @doc shapes are unaffected" do
    test "a literal doc still gets its contract sections" do
      doc = doc_text(:twice, 1)

      assert doc =~ "A plain literal doc."
      assert doc =~ "#### Preconditions"
      assert doc =~ "pos: y > 0"
    end

    test "@doc false stays hidden" do
      assert doc_text(:hidden, 1) == :hidden
    end

    test "@doc with only metadata gets synthesised contract docs" do
      doc = doc_text(:metadata_only, 1)

      assert doc =~ "#### Preconditions"
      assert doc =~ "pos: n > 0"
    end

    test "metadata keyword lists are preserved" do
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(InterpolatedDocs)

      meta =
        Enum.find_value(docs, fn
          {{:function, :metadata_only, 1}, _, _, _, meta} -> meta
          _ -> nil
        end)

      assert meta[:since] == "1.0.0"
    end
  end

  describe "runtime behaviour is unchanged" do
    test "contracts on a function with an interpolated doc still fire" do
      assert InterpolatedDocs.new(3) == %InterpolatedDocs{x: 3}
      assert_raise Bond.PreconditionError, fn -> InterpolatedDocs.new(0) end
    end
  end
end
