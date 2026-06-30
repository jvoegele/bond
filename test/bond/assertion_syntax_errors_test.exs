defmodule Bond.AssertionSyntaxErrorsTest do
  @moduledoc """
  Verifies clear `CompileError`s for assertion-syntax misuses that previously
  produced unhelpful Kernel-level arity errors. `Bond.@/1` has catch-all clauses
  for `@pre`/`@post`/`@invariant` calls with 2+ arguments that don't match the
  single-arg (bare or keyword-list) form. (The positional label forms a 2-arg
  call could once take were removed in 1.0 — those specific shapes raise a
  migration error; see `migration_errors_test.exs`.)

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

  describe "bare literal as the assertion" do
    test "@pre with a bare integer raises a Bond-shaped CompileError" do
      code = """
      defmodule Bond.AssertionSyntaxErrorsTest.BareInteger do
        use Bond
        @pre 42
        def f(x), do: x
      end
      """

      assert_raise CompileError, ~r/Bond assertion is not a valid Elixir expression/, fn ->
        Code.eval_string(code)
      end
    end

    test "@pre with a bare string raises with the source in the message" do
      code = """
      defmodule Bond.AssertionSyntaxErrorsTest.BareString do
        use Bond
        @pre "hello"
        def f(x), do: x
      end
      """

      assert_raise CompileError, ~r/"hello"/, fn ->
        Code.eval_string(code)
      end
    end

    test "@invariant with a bare atom raises a Bond-shaped CompileError" do
      code = """
      defmodule Bond.AssertionSyntaxErrorsTest.BareAtomInvariant do
        use Bond
        defstruct [:x]
        @invariant :something
        def get(%__MODULE__{} = s), do: s
      end
      """

      assert_raise CompileError, ~r/Bond assertion is not a valid Elixir expression/, fn ->
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

    test "keyword form with a quoted-string label (the migration path for positional string labels) compiles" do
      code = """
      defmodule Bond.AssertionSyntaxErrorsTest.QuotedStringLabel do
        use Bond
        @pre "x must be positive": x > 0
        def f(x), do: x
      end
      """

      assert {{:module, _, _, _}, _} = Code.eval_string(code)
    end
  end

  describe "where/whenever (#47) binding-form diagnostics" do
    test "where with a `<-` arrow raises (where uses `=`)" do
      code = """
      defmodule Bond.AssertionSyntaxErrorsTest.WhereWrongArrow do
        use Bond
        @post where({:ok, x} <- result), pos: x > 0
        def f, do: {:ok, 1}
      end
      """

      assert_raise CompileError, ~r/`where` requires a `pattern = source` binding/, fn ->
        Code.eval_string(code)
      end
    end

    test "whenever with a `=` arrow raises (whenever uses `<-`)" do
      code = """
      defmodule Bond.AssertionSyntaxErrorsTest.WheneverWrongArrow do
        use Bond
        @post whenever({:ok, x} = result), pos: x > 0
        def f, do: {:ok, 1}
      end
      """

      assert_raise CompileError, ~r/`whenever` requires a `pattern <- source` binding/, fn ->
        Code.eval_string(code)
      end
    end

    test "where with no scoped assertions raises, pointing at `<~`" do
      code = """
      defmodule Bond.AssertionSyntaxErrorsTest.WhereNoBody do
        use Bond
        @post where({:ok, _x} = result)
        def f, do: {:ok, 1}
      end
      """

      assert_raise CompileError, ~r/needs at least one assertion.*<~/s, fn ->
        Code.eval_string(code)
      end
    end

    test "a non-binding argument to where raises the binding diagnostic" do
      code = """
      defmodule Bond.AssertionSyntaxErrorsTest.WhereNonBinding do
        use Bond
        @post where(is_tuple(result)), ok: is_tuple(result)
        def f, do: {:ok, 1}
      end
      """

      assert_raise CompileError, ~r/`where` requires a `pattern = source` binding/, fn ->
        Code.eval_string(code)
      end
    end

    test "the same diagnostics apply on @pre" do
      code = """
      defmodule Bond.AssertionSyntaxErrorsTest.PreWhereWrongArrow do
        use Bond
        @pre where({:ok, x} <- arg), pos: x > 0
        def f(arg), do: arg
      end
      """

      assert_raise CompileError, ~r/`where` requires a `pattern = source` binding/, fn ->
        Code.eval_string(code)
      end
    end

    # where/whenever IS supported in behaviour/protocol contracts (#47); the inheritance behaviour
    # and its validation diagnostics are covered in where_whenever_inheritance_test.exs.
  end
end
