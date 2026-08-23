defmodule Bond.Compiler.ContractDocsTest do
  @moduledoc false

  use ExUnit.Case

  alias Bond.Compiler.Assertion
  alias Bond.Compiler.ContractDocs

  # The text between the opening ```elixir fence and its closing ```. A continuation line that
  # escaped the block would land outside this, which is the whole point of the #109 fix.
  defp fenced_body(section) do
    [_before, body | _] = String.split(section, ~r/^```(elixir)?$/m, parts: 3)
    String.trim(body)
  end

  describe "moduledoc_invariants_section/3" do
    test "returns nil when the module has no invariants" do
      assert ContractDocs.moduledoc_invariants_section([], MyMod, true) == nil
    end

    test "returns nil when invariants are :purge'd" do
      invariants = [assertion(:non_negative, quote(do: subject.x >= 0))]
      assert ContractDocs.moduledoc_invariants_section(invariants, MyMod, :purge) == nil
    end

    test "returns a section with the canonical structure" do
      invariants = [assertion(:non_negative, quote(do: subject.x >= 0))]
      section = ContractDocs.moduledoc_invariants_section(invariants, MyMod, true)

      assert is_binary(section)
      assert section =~ "## Invariants"
      assert section =~ "%MyMod{}"
      assert section =~ "subject"
      assert section =~ "non_negative: subject.x >= 0"
      assert section =~ "Eiffel convention"
    end

    test "renders the labelled-form (`label: expression`) for each invariant" do
      invariants = [
        assertion(:non_negative_capacity, quote(do: subject.capacity >= 0)),
        assertion(:size_within_capacity, quote(do: length(subject.items) <= subject.capacity))
      ]

      section = ContractDocs.moduledoc_invariants_section(invariants, BoundedStack, true)

      assert section =~ "non_negative_capacity: subject.capacity >= 0"
      assert section =~ "size_within_capacity: length(subject.items) <= subject.capacity"
    end

    test "renders bare-form (no label) when an invariant has no label" do
      invariants = [assertion(nil, quote(do: subject.x > 0))]
      section = ContractDocs.moduledoc_invariants_section(invariants, MyMod, true)

      assert section =~ "subject.x > 0"
      # Make sure no stray `nil:` or `:nil` leaks into the output.
      refute section =~ ~r/nil:/
    end

    test "renders a string label (with quotes stripped by inspect/trim) cleanly" do
      invariants = [assertion("size is positive", quote(do: subject.size > 0))]
      section = ContractDocs.moduledoc_invariants_section(invariants, MyMod, true)

      assert section =~ ~s|"size is positive": subject.size > 0|
    end

    test "wraps the invariants in a fenced elixir code block" do
      invariants = [
        assertion(:a, quote(do: subject.a >= 0)),
        assertion(:b, quote(do: subject.b >= 0))
      ]

      section = ContractDocs.moduledoc_invariants_section(invariants, MyMod, true)

      assert section =~ ~r/^```elixir\na: subject\.a >= 0\nb: subject\.b >= 0\n```$/m
    end

    test "a wrapped assertion stays inside the code block (#109)" do
      # `code` is `Macro.to_string/1` output, so it runs the formatter and wraps once it exceeds
      # the line length. Under the previous 4-space-indented block only the *first* line of an
      # assertion got the indent, and the continuation — carrying the formatter's own 0 or 2
      # spaces — fell below Markdown's threshold and ended the block.
      long =
        quote do
          is_nil(subject.refresh_token) or
            (is_binary(subject.refresh_token) and subject.refresh_token != "")
        end

      section =
        ContractDocs.moduledoc_invariants_section(
          [assertion(:short, quote(do: is_list(subject.scopes))), assertion(:wrapped, long)],
          MyMod,
          true
        )

      rendered = fenced_body(section)

      assert String.contains?(rendered, "\n"), "expected the fixture assertion to wrap"

      # Everything between the fences, continuation lines included.
      assert rendered =~ "short: is_list(subject.scopes)"
      assert rendered =~ "wrapped: is_nil(subject.refresh_token) or"
      assert rendered =~ ~s|(is_binary(subject.refresh_token) and subject.refresh_token != "")|
    end

    test "names a nested module correctly" do
      invariants = [assertion(:p, quote(do: subject.id > 0))]

      section = ContractDocs.moduledoc_invariants_section(invariants, MyApp.Domain.Account, true)

      assert section =~ "%MyApp.Domain.Account{}"
    end

    test "produces no extra blank lines or trailing whitespace artifacts" do
      invariants = [assertion(:p, quote(do: subject.x))]
      section = ContractDocs.moduledoc_invariants_section(invariants, MyMod, true)

      refute section =~ ~r/\n\n\n/
      refute section =~ ~r/[ \t]+$/m
    end
  end

  # Helpers ---------------------------------------------------------------

  defp assertion(label, expression) do
    Assertion.new(:invariant, label, expression, __ENV__)
  end
end
