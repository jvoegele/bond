defmodule Bond.ModuledocInvariantsTest do
  @moduledoc """
  End-to-end tests for the auto-generated `## Invariants` section in the
  `@moduledoc` of any module that declares `@invariant`s. Verifies the
  section appears in the compiled module's documentation chunk, respects
  `invariants: :purge` suppression, and respects `@moduledoc false`.

  Fixtures live in `test/support/bond_test/`: those modules are compiled
  with the rest of the project, so their docs chunks are accessible via
  `Code.fetch_docs/1`.
  """

  use ExUnit.Case

  describe "auto-generated `## Invariants` moduledoc section" do
    test "appears in a module that has @invariant and a user @moduledoc" do
      doc = fetch_moduledoc(BondTest.SubjectInvariantSmoke)

      assert is_binary(doc)
      # User-authored content is preserved (the user's moduledoc opens with this).
      assert doc =~ "Fixture exercising the 0.16.0"
      # Generated section follows.
      assert doc =~ "## Invariants"
      assert doc =~ "%BondTest.SubjectInvariantSmoke{}"
      assert doc =~ "non_negative_capacity: subject.capacity >= 0"
      assert doc =~ "size_within_capacity: length(subject.items) <= subject.capacity"
    end

    test "section explains the `subject` binding for module-level readers" do
      doc = fetch_moduledoc(BondTest.SubjectInvariantSmoke)

      assert doc =~ "`subject` refers"
      assert doc =~ "value being checked"
    end

    test "section explains when invariants fire and the defp exemption" do
      doc = fetch_moduledoc(BondTest.SubjectInvariantSmoke)

      assert doc =~ "checked automatically on entry to and exit from every public"
      assert doc =~ "Private functions are exempt"
    end

    test "section appears after (not before) the user's authored content" do
      doc = fetch_moduledoc(BondTest.SubjectInvariantSmoke)

      user_pos = :binary.match(doc, "Fixture exercising") |> elem(0)
      generated_pos = :binary.match(doc, "## Invariants") |> elem(0)

      assert user_pos < generated_pos,
             "expected the user's content to precede the generated section"
    end
  end

  describe "synthesised moduledoc when the user didn't write one" do
    test "creates a moduledoc with just the Invariants section" do
      doc = fetch_moduledoc(BondTest.SynthesizedModuledocInvariant)

      assert is_binary(doc)
      assert doc =~ "## Invariants"
      assert doc =~ "non_negative: subject.n >= 0"
    end
  end

  describe "@moduledoc false respected" do
    test "Bond doesn't override @moduledoc false — the module remains hidden" do
      moduledoc = fetch_raw_moduledoc(BondTest.HiddenModuledocFixture)
      # `@moduledoc false` renders as `:hidden` in Code.fetch_docs/1.
      assert moduledoc == :hidden
    end
  end

  describe "module without @invariant declarations" do
    test "no Invariants section is added to a module without invariants" do
      doc = fetch_moduledoc(BondTest.Math)

      assert is_binary(doc) or doc == :none
      if is_binary(doc), do: refute(doc =~ "## Invariants")
    end
  end

  describe "invariants: :purge suppresses the generated section" do
    test "user-authored moduledoc is preserved verbatim, no section appended" do
      doc = fetch_moduledoc(BondTest.PurgedInvariantsFixture)

      assert is_binary(doc)
      # User's content is preserved.
      assert doc =~ "User-authored moduledoc"
      # Generated section is suppressed.
      refute doc =~ "## Invariants"
    end
  end

  # Helpers ---------------------------------------------------------------

  defp fetch_moduledoc(module) do
    case fetch_raw_moduledoc(module) do
      %{"en" => content} -> content
      other -> other
    end
  end

  defp fetch_raw_moduledoc(module) do
    {:docs_v1, _anno, _lang, _format, moduledoc, _meta, _fn_docs} = Code.fetch_docs(module)
    moduledoc
  end
end
