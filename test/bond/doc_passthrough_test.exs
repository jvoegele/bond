defmodule Bond.DocPassthroughTest do
  @moduledoc """
  `@doc` must survive whether or not Bond generates an override for the function (#71).

  Bond's `@doc` override records the value so `@before_compile` can re-emit it with the generated
  contract sections appended. When it *only* recorded it, any function Bond did not wrap lost its
  documentation silently: an uncontracted function, or any function in a module compiled with
  contracts purged. `@doc` is now emitted where the user wrote it as well, and the re-emission
  overrides it via a bodiless function head.

  Fixtures live in `test/support` because `Code.fetch_docs/1` needs an on-disk beam.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias BondTest.DocPassthrough
  alias BondTest.DocPassthroughNoAtAnnotations
  alias BondTest.DocPassthroughPurged

  describe "a wrapped assertion stays inside its code block (#109)" do
    test "the continuation line is inside the fence, not loose prose after it" do
      text = doc(DocPassthrough, :wrapping, 1)

      [_prose, contracts] = String.split(text, "#### Preconditions", parts: 2)
      [_before, body | _] = String.split(contracts, ~r/^```(elixir)?$/m, parts: 3)

      # The fixture assertion is long enough that the formatter wraps it; if it ever stops
      # wrapping this test proves nothing, so assert that first.
      assert String.contains?(String.trim(body), "\n"),
             "expected the fixture assertion to wrap; it no longer does"

      assert String.trim(body) =~ "wrapping: is_binary(token)"
      assert String.trim(body) =~ ~s|token != "tok_"|
    end
  end

  defp doc(module, fun, arity) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(module)

    case Enum.find_value(docs, fn
           {{:function, ^fun, ^arity}, _, _, d, _} -> d
           _ -> nil
         end) do
      %{"en" => text} -> text
      other -> other
    end
  end

  describe "functions Bond does not wrap" do
    test "an uncontracted function keeps its doc" do
      assert doc(DocPassthrough, :doc_only, 1) == "Doc-only, uncontracted."
    end

    test "an uncontracted function following a contracted one keeps its doc" do
      assert doc(DocPassthrough, :doc_only_after, 1) ==
               "Doc-only, following a contracted function."
    end

    test "a contracted function keeps its doc when every kind is purged" do
      # `:purge` emits no override at all, so nothing would re-emit a recorded doc.
      assert doc(DocPassthroughPurged, :f, 1) == "Contracted, but every kind is purged."
    end
  end

  describe "functions Bond does wrap" do
    test "keep the user's prose and gain the contract sections" do
      text = doc(DocPassthrough, :contracted, 1)

      assert text =~ "Contracted."
      assert text =~ "#### Preconditions"
      assert text =~ "pos: y > 0"
    end

    test "the prose comes before the contract sections" do
      [prose, _] =
        String.split(doc(DocPassthrough, :contracted, 1), "#### Preconditions", parts: 2)

      assert prose =~ "Contracted."
    end

    test "multi-clause functions keep both halves" do
      text = doc(DocPassthrough, :multi, 1)

      assert text =~ "Multi-clause with a guard."
      assert text =~ "pos: n > 0"
    end

    test "functions with default arguments keep both halves" do
      text = doc(DocPassthrough, :defaults, 2)

      assert text =~ "Default arguments."
      assert text =~ "pos: a > 0"
    end

    test "interpolated docs are still evaluated and appended to" do
      text = doc(DocPassthrough, :interpolated, 1)

      assert text =~ "Interpolated widgets, contracted."
      assert text =~ "#### Preconditions"
    end

    test "a contracted function with no user doc still gets synthesised contract docs" do
      text = doc(DocPassthrough, :undocumented, 1)

      assert text =~ "#### Preconditions"
      assert text =~ "pos: x > 0"
    end
  end

  describe "runtime behaviour is unchanged" do
    test "contracts still fire" do
      assert DocPassthrough.contracted(1) == 1
      assert_raise Bond.PreconditionError, fn -> DocPassthrough.contracted(0) end
    end

    test "multi-clause dispatch survives the bodiless head" do
      assert DocPassthrough.multi(5) == 5
      assert DocPassthrough.multi(5.0) == 5.0
    end

    test "default arguments survive the bodiless head" do
      assert DocPassthrough.defaults(1) == {1, 2}
      assert DocPassthrough.defaults(1, 9) == {1, 9}
    end
  end

  describe "at_annotations: false" do
    test "leaves the user's prose alone" do
      # Bond never sees `@doc` in this mode, so it must not emit a contract-section doc that
      # would replace what the user wrote.
      assert doc(DocPassthroughNoAtAnnotations, :b, 1) == "User prose Bond must not overwrite."
    end

    test "still enforces the contract" do
      assert DocPassthroughNoAtAnnotations.b(1) == 1
      assert_raise Bond.PreconditionError, fn -> DocPassthroughNoAtAnnotations.b(0) end
    end
  end

  describe "compile-time warnings" do
    test "overriding the user's doc does not warn about redefining @doc" do
      warning =
        BondTest.Diagnostics.warnings("""
        defmodule BondTest.NoRedefineWarning do
          use Bond
          @doc "prose"
          @pre pos: x > 0
          def f(x), do: x
        end
        """)

      refute warning =~ "redefining @doc"
    end

    test "@doc on a private function now warns, as plain Elixir would" do
      # Bond used to swallow this by recording the doc and never emitting it for `defp`.
      warning =
        capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule BondTest.DocOnDefp do
            use Bond
            @doc "doc on a private helper"
            @pre pos: x > 0
            defp helper(x), do: x
            def pub(x), do: helper(x)
          end
          """)
        end)

      assert warning =~ "private"
    end
  end
end
