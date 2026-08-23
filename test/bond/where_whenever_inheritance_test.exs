defmodule Bond.WhereWheneverInheritanceTest do
  @moduledoc """
  `where`/`whenever` binding forms (#47) in inherited contracts — `Bond.Behaviour` callbacks and
  `Bond.Protocol` functions. The binding group is captured at the abstraction, round-trips through
  the reflection, and re-materialises in the implementer via the same grouped codegen as a direct
  `@pre`/`@post`.
  """
  use ExUnit.Case, async: false

  # --- Behaviour: whenever (conditional), with quantifiers over the bound value ---
  defmodule Calc do
    use Bond.Behaviour
    import Bond.Predicates

    @post whenever({:ok, items} <- result),
      nonempty: items != [],
      all_pos: forall(i <- items, i > 0)
    @callback compute(n :: integer()) :: {:ok, list(integer())} | {:error, term()}
  end

  defmodule GoodCalc do
    use Bond, behaviours: [Calc]
    @impl Calc
    def compute(n) when n > 0, do: {:ok, Enum.to_list(1..n)}
    def compute(_), do: {:error, :nonpos}
  end

  defmodule BadCalc do
    use Bond, behaviours: [Calc]
    @impl Calc
    def compute(_n), do: {:ok, [0, -1]}
  end

  describe "behaviour inheritance of whenever" do
    test "passes on a matching ok with valid members" do
      assert {:ok, [1, 2, 3]} = GoodCalc.compute(3)
    end

    test "is vacuous on a non-matching shape" do
      assert {:error, :nonpos} = GoodCalc.compute(-1)
    end

    test "a member violation raises, attributed to the source behaviour" do
      error = assert_raise Bond.PostconditionError, fn -> BadCalc.compute(2) end
      assert error.label == :all_pos
      assert error.source_behaviour == Calc
    end
  end

  # --- Behaviour: where (assert) ---
  defmodule Parser do
    use Bond.Behaviour
    @post where({:ok, n} = result), non_neg: n >= 0
    @callback parse(s :: binary()) :: {:ok, integer()}
  end

  defmodule GoodParser do
    use Bond, behaviours: [Parser]
    @impl Parser
    def parse(_s), do: {:ok, 7}
  end

  defmodule WrongShapeParser do
    use Bond, behaviours: [Parser]
    @impl Parser
    def parse(_s), do: :nope
  end

  describe "behaviour inheritance of where (assert)" do
    test "passes for a matching shape with valid members" do
      assert {:ok, 7} = GoodParser.parse("x")
    end

    test "a non-matching shape is a :shape violation" do
      error = assert_raise Bond.PostconditionError, fn -> WrongShapeParser.parse("x") end
      assert error.label == :shape
    end
  end

  # --- Protocol: where enforced at the dispatch boundary ---
  defprotocol Sized do
    use Bond.Protocol
    @post where({:ok, n} = result), non_neg: n >= 0
    def measure(t)
  end

  defmodule Box do
    defstruct count: 0
  end

  defmodule NegBox do
    defstruct []
  end

  defimpl Sized, for: Box do
    def measure(%Box{count: c}), do: {:ok, c}
  end

  defimpl Sized, for: NegBox do
    def measure(%NegBox{}), do: {:ok, -5}
  end

  describe "protocol inheritance of where" do
    test "passes when the impl honours the contract" do
      assert {:ok, 3} = Sized.measure(%Box{count: 3})
    end

    test "a violation at the dispatch boundary raises" do
      error = assert_raise Bond.PostconditionError, fn -> Sized.measure(%NegBox{}) end
      assert error.label == :non_neg
    end
  end

  # --- All-inside form, on both inherited paths (#106) ---
  #
  # `public-api.md` documents `where(binding, assertions…)` as an alias of the prefix form
  # `where(binding), assertions…`, and says so specifically for inherited contracts. It was
  # rejected on both, with the diagnostic written for a genuinely nested binder — so the message
  # read "you wrote this in the wrong place" when the binder *was* at the start of the contract.
  defmodule InsideCalc do
    use Bond.Behaviour
    # `out`, not `n`: a bound name that collides with a callback argument leaves that argument
    # unused in the generated postcondition defp and warns. That is pre-existing and identical
    # for the prefix form — not something this alias introduces — but it is noise here.
    @post whenever({:ok, out} <- result, non_neg: out >= 0)
    @callback compute(n :: integer()) :: {:ok, integer()} | :error
  end

  defmodule GoodInsideCalc do
    use Bond, behaviours: [InsideCalc]
    @impl InsideCalc
    def compute(n) when n >= 0, do: {:ok, n}
    def compute(_), do: :error
  end

  defmodule BadInsideCalc do
    use Bond, behaviours: [InsideCalc]
    @impl InsideCalc
    def compute(_n), do: {:ok, -1}
  end

  describe "behaviour inheritance of the all-inside form" do
    test "passes on a matching result with a valid member" do
      assert {:ok, 3} = GoodInsideCalc.compute(3)
    end

    test "is vacuous on a non-matching shape, exactly as the prefix form is" do
      assert :error = GoodInsideCalc.compute(-1)
    end

    test "a member violation raises, attributed to the source behaviour" do
      error = assert_raise Bond.PostconditionError, fn -> BadInsideCalc.compute(1) end
      assert error.label == :non_neg
      assert error.source_behaviour == InsideCalc
    end
  end

  defprotocol InsideSized do
    use Bond.Protocol
    @post where({:ok, n} = result, non_neg: n >= 0)
    def measure(t)
  end

  defmodule InsideBox do
    defstruct count: 0
  end

  defmodule InsideNegBox do
    defstruct []
  end

  defmodule InsideWrongShape do
    defstruct []
  end

  defimpl InsideSized, for: InsideBox do
    def measure(%InsideBox{count: c}), do: {:ok, c}
  end

  defimpl InsideSized, for: InsideNegBox do
    def measure(%InsideNegBox{}), do: {:ok, -5}
  end

  defimpl InsideSized, for: InsideWrongShape do
    def measure(%InsideWrongShape{}), do: :nope
  end

  describe "protocol inheritance of the all-inside form" do
    test "passes when the impl honours the contract" do
      assert {:ok, 3} = InsideSized.measure(%InsideBox{count: 3})
    end

    test "a member violation at the dispatch boundary raises" do
      error = assert_raise Bond.PostconditionError, fn -> InsideSized.measure(%InsideNegBox{}) end
      assert error.label == :non_neg
    end

    test "a non-matching shape is a :shape violation, since `where` asserts the shape" do
      error =
        assert_raise Bond.PostconditionError, fn -> InsideSized.measure(%InsideWrongShape{}) end

      assert error.label == :shape
    end
  end

  describe "the all-inside form is an alias, not a second dialect" do
    test "a body-less `where(...)` is still diagnosed by the shared parser" do
      # The all-inside clause must sit *below* the prefix clause, or this shape would be read as
      # a binding group with no members instead of reaching the parser's diagnostic.
      code = """
      defmodule Bond.WhereWheneverInheritanceTest.NoMembers do
        use Bond.Behaviour
        @post where({:ok, n} = result)
        @callback f() :: {:ok, integer()}
      end
      """

      assert_raise CompileError, fn -> Code.eval_string(code) end
    end

    test "a member referencing a non-argument name raises the same error as the prefix form" do
      code = """
      defmodule Bond.WhereWheneverInheritanceTest.InsideBadRef do
        use Bond.Behaviour
        @post where({:ok, n} = result, bad: n > limit)
        @callback f() :: {:ok, integer()}
      end
      """

      assert_raise CompileError, ~r/limit.*not a callback argument/s, fn ->
        Code.eval_string(code)
      end
    end
  end

  describe "validation at the abstraction" do
    test "a member referencing a non-argument name raises a clear error" do
      code = """
      defmodule Bond.WhereWheneverInheritanceTest.BadRef do
        use Bond.Behaviour
        @post where({:ok, n} = result), bad: n > limit
        @callback f() :: {:ok, integer()}
      end
      """

      assert_raise CompileError, ~r/limit.*not a callback argument/s, fn ->
        Code.eval_string(code)
      end
    end

    test "a binding source referencing an undeclared argument raises" do
      code = """
      defmodule Bond.WhereWheneverInheritanceTest.BadSource do
        use Bond.Behaviour
        @pre where({:ok, x} = arg), ok: x > 0
        @callback f(n :: integer()) :: :ok
      end
      """

      assert_raise CompileError, ~r/arg.*not a callback argument/s, fn ->
        Code.eval_string(code)
      end
    end
  end
end
