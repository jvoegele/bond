defmodule Bond.Compiler.ContractDocsTest do
  @moduledoc false

  use ExUnit.Case

  alias Bond.Compiler.Assertion
  alias Bond.Compiler.ContractDocs

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

    test "indents each invariant line as a 4-space markdown code block" do
      invariants = [
        assertion(:a, quote(do: subject.a >= 0)),
        assertion(:b, quote(do: subject.b >= 0))
      ]

      section = ContractDocs.moduledoc_invariants_section(invariants, MyMod, true)

      # Every invariant line begins with 4 spaces (markdown code block).
      assert section =~ ~r/^\s{4}a: subject\.a >= 0/m
      assert section =~ ~r/^\s{4}b: subject\.b >= 0/m
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
