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
