defmodule Bond.AssertionSyntaxErrorsTest do
  @moduledoc """
  Verifies clear `CompileError`s for assertion-syntax misuses that previously
  produced unhelpful Kernel-level arity errors. 0.16.2 adds catch-all clauses
  to `Bond.@/1` for `@pre`/`@post`/`@invariant` calls with 2+ arguments that
  don't match the existing label-first / label-last / single-arg patterns.

  Each test compiles a small fixture module via `Code.eval_string/1` and
  asserts the expected `CompileError` surfaces with a regex match against
  the diagnostic message.
  """

  use ExUnit.Case

  describe "@pre with bare + labelled mixed" do
    test "raises CompileError pointing at separate-line and label-every-assertion fixes" do
      code = """
      defmodule Bond.AssertionSyntaxErrorsTest.PreMixed do
        use Bond

        @pre is_binary(x), positive: x > 0
        def f(x), do: x
      end
      """

      assert_raise CompileError, ~r/@pre accepts a single argument/, fn ->
        Code.eval_string(code)
      end
    end
  end

  describe "@post with bare + labelled mixed" do
    test "raises CompileError with the @post-specific message" do
      code = """
      defmodule Bond.AssertionSyntaxErrorsTest.PostMixed do
        use Bond

        @post is_integer(result), positive: result > 0
        def f(x), do: x
      end
      """

      assert_raise CompileError, ~r/@post accepts a single argument/, fn ->
        Code.eval_string(code)
      end
    end
  end

  describe "@pre with two bare assertions in one line" do
    test "raises CompileError — two bare expressions aren't valid in one call" do
      code = """
      defmodule Bond.AssertionSyntaxErrorsTest.TwoBare do
        use Bond

        @pre is_integer(x), x > 0
        def f(x), do: x
      end
      """

      assert_raise CompileError, ~r/@pre accepts a single argument.*Got 2 arguments/s, fn ->
        Code.eval_string(code)
      end
    end
  end

  describe "@invariant with bare + labelled mixed" do
    test "raises CompileError with the @invariant-specific message" do
      code = """
      defmodule Bond.AssertionSyntaxErrorsTest.InvariantMixed do
        use Bond
        defstruct [:x, :y]

        @invariant subject.x >= 0, positive: subject.y > 0
        def get(%__MODULE__{} = s), do: s
      end
      """

      assert_raise CompileError, ~r/@invariant accepts a single argument/, fn ->
        Code.eval_string(code)
      end
    end
  end

  describe "existing valid forms still work" do
    test "single bare assertion compiles" do
      code = """
      defmodule Bond.AssertionSyntaxErrorsTest.SingleBare do
        use Bond
        @pre is_integer(x)
        def f(x), do: x
      end
      """

      assert {{:module, _, _, _}, _} = Code.eval_string(code)
    end

    test "keyword-list form compiles" do
      code = """
      defmodule Bond.AssertionSyntaxErrorsTest.KwList do
        use Bond
        @pre is_integer: is_integer(x), positive: x > 0
        def f(x), do: x
      end
      """

      assert {{:module, _, _, _}, _} = Code.eval_string(code)
    end

    test "multiple separate @pre lines compile" do
      code = """
      defmodule Bond.AssertionSyntaxErrorsTest.MultiLine do
        use Bond
        @pre is_integer(x)
        @pre x > 0
        def f(x), do: x
      end
      """

      assert {{:module, _, _, _}, _} = Code.eval_string(code)
    end

    test "atom-label-first form compiles" do
      code = """
      defmodule Bond.AssertionSyntaxErrorsTest.AtomLabelFirst do
        use Bond
        @pre :positive, x > 0
        def f(x), do: x
      end
      """

      assert {{:module, _, _, _}, _} = Code.eval_string(code)
    end

    test "string-label-last form compiles" do
      code = """
      defmodule Bond.AssertionSyntaxErrorsTest.StringLabelLast do
        use Bond
        @pre x > 0, "positive"
        def f(x), do: x
      end
      """

      assert {{:module, _, _, _}, _} = Code.eval_string(code)
    end
  end
end
