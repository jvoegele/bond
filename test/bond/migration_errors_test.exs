defmodule Bond.MigrationErrorsTest do
  @moduledoc """
  Verifies that legacy macro shapes removed in 0.16.0 raise `CompileError` with the
  migration message rather than producing cryptic errors. Two breaks are covered:

    * Legacy `@invariant <name>, <expr>` (was the 0.13–0.15 shape).
    * `check/2` (the two string-label forms `check "lbl", expr` and `check expr, "lbl"`).

  Each test compiles a small fixture module via `Code.eval_string/1` and asserts the
  expected CompileError surfaces with a regex match against the migration message.
  """

  use ExUnit.Case

  describe "legacy @invariant <name>, <expr> form" do
    test "raises CompileError pointing at the new subject-binding syntax" do
      code = """
      defmodule Bond.MigrationErrorsTest.LegacyInvariant do
        use Bond
        defstruct [:value]
        @invariant value, value >= 0
        def get(%__MODULE__{} = s), do: s.value
      end
      """

      assert_raise CompileError, ~r/@invariant <name>, <expr> was removed in Bond 0\.16\.0/, fn ->
        Code.eval_string(code)
      end
    end
  end

  describe "legacy check/2 string-label form" do
    test "raises CompileError pointing at the keyword-list form" do
      code = """
      defmodule Bond.MigrationErrorsTest.LegacyCheckStringFirst do
        use Bond

        def must_be_positive(n) do
          check "n is positive", n > 0
          n
        end
      end
      """

      assert_raise CompileError, ~r/check\/2 was removed in Bond 0\.16\.0/, fn ->
        Code.eval_string(code)
      end
    end

    test "raises CompileError for the reversed `check expr, label` arity-2 shape" do
      code = """
      defmodule Bond.MigrationErrorsTest.LegacyCheckStringLast do
        use Bond

        def must_be_positive(n) do
          check n > 0, "n is positive"
          n
        end
      end
      """

      assert_raise CompileError, ~r/check\/2 was removed in Bond 0\.16\.0/, fn ->
        Code.eval_string(code)
      end
    end
  end
end
