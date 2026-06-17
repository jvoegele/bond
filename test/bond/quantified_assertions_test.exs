defmodule Bond.QuantifiedAssertionsTest do
  @moduledoc """
  Integration tests for the `forall`/`exists` quantified assertions (#32) across every
  assertion kind — `@pre`, `@post` (including quantifying over `result`), `@invariant`, and
  `Bond.check/1` — plus the element-level `counterexample:` diagnostic, the side-channel
  staleness mitigation, and the compile-time generator-syntax guard.
  """

  use ExUnit.Case, async: false

  defmodule PreFixture do
    @moduledoc false
    use Bond

    @pre all_positive: forall(x <- items, x > 0)
    def scale(items), do: Enum.map(items, &(&1 * 2))

    @pre has_admin: exists(u <- users, u.role == :admin)
    def authorize(users), do: {:ok, Enum.count(users)}
  end

  defmodule PostFixture do
    @moduledoc false
    use Bond

    @post all_positive: forall(x <- result, x > 0)
    def doubled(items), do: Enum.map(items, &(&1 * 2))
  end

  defmodule CheckFixture do
    @moduledoc false
    use Bond

    def first(items) do
      check all_positive: forall(x <- items, x > 0)
      hd(items)
    end
  end

  defmodule InvariantFixture do
    @moduledoc false
    use Bond

    defstruct coords: []

    @invariant all_nonneg: forall(c <- subject.coords, c >= 0)
    def new(coords), do: %__MODULE__{coords: coords}
  end

  defmodule StaleFixture do
    @moduledoc false
    use Bond

    # `absorbed` PASSES: the inner `forall` fails (no element > 100), but `not` absorbs that
    # into a truthy result — so its element detail must NOT leak into `plain`'s failure below.
    @pre absorbed: not forall(x <- xs, x > 100)
    @pre plain: y > 0
    def f(xs, y), do: {xs, y}
  end

  defmodule EmptyFixture do
    @moduledoc false
    use Bond

    @pre all_positive: forall(x <- items, x > 0)
    def all_pos(items), do: items

    @pre any_positive: exists(x <- items, x > 0)
    def any_pos(items), do: items
  end

  describe "@pre forall" do
    test "passes when every element satisfies the predicate" do
      assert PreFixture.scale([1, 2, 3]) == [2, 4, 6]
    end

    test "fails with the offending element and index in the message" do
      error = assert_raise Bond.PreconditionError, fn -> PreFixture.scale([5, 2, 8, -2]) end
      message = Exception.message(error)

      assert message =~ "label: :all_positive"
      assert message =~ "assertion: forall(x <- items, x > 0)"
      assert message =~ "counterexample: element at index 3 (-2) does not satisfy `x > 0`"
    end
  end

  describe "@pre exists" do
    test "passes when at least one element satisfies the predicate" do
      assert PreFixture.authorize([%{role: :user}, %{role: :admin}]) == {:ok, 2}
    end

    test "fails reporting that no element satisfies the predicate, with the count" do
      error =
        assert_raise Bond.PreconditionError, fn ->
          PreFixture.authorize([%{role: :user}, %{role: :guest}])
        end

      assert Exception.message(error) =~
               "counterexample: no element of `users` satisfies `u.role == :admin` (2 elements)"
    end
  end

  describe "@post forall over result" do
    test "passes when the result satisfies the predicate" do
      assert PostFixture.doubled([1, 2, 3]) == [2, 4, 6]
    end

    test "fails reporting the offending element of the result" do
      error = assert_raise Bond.PostconditionError, fn -> PostFixture.doubled([1, -1, 2]) end

      assert Exception.message(error) =~
               "counterexample: element at index 1 (-2) does not satisfy `x > 0`"
    end
  end

  describe "check with forall" do
    test "passes through the value when the predicate holds for all elements" do
      assert CheckFixture.first([1, 2, 3]) == 1
    end

    test "raises a CheckError with element-level detail" do
      error = assert_raise Bond.CheckError, fn -> CheckFixture.first([1, -5, 3]) end

      assert Exception.message(error) =~
               "counterexample: element at index 1 (-5) does not satisfy `x > 0`"
    end
  end

  describe "@invariant forall over subject" do
    test "passes when every element satisfies the invariant" do
      assert %InvariantFixture{coords: [0, 1, 2]} = InvariantFixture.new([0, 1, 2])
    end

    test "fails with the offending element of the subject" do
      error = assert_raise Bond.InvariantError, fn -> InvariantFixture.new([0, 3, -7]) end

      assert Exception.message(error) =~
               "counterexample: element at index 2 (-7) does not satisfy `c >= 0`"
    end
  end

  describe "empty enumerable semantics" do
    test "forall is vacuously true" do
      assert EmptyFixture.all_pos([]) == []
    end

    test "exists is false (no witness)" do
      assert_raise Bond.PreconditionError, fn -> EmptyFixture.any_pos([]) end
    end
  end

  describe "side-channel staleness mitigation" do
    test "an absorbed quantifier failure does not leak into a later assertion's message" do
      # `absorbed` passes (forall fails internally, `not` absorbs it); `plain` then fails for
      # an unrelated reason. Its message must report :plain with NO counterexample line.
      error = assert_raise Bond.PreconditionError, fn -> StaleFixture.f([1, 2, 3], -5) end
      message = Exception.message(error)

      assert message =~ "label: :plain"
      refute message =~ "counterexample"
    end
  end

  defmodule NestedFixture do
    @moduledoc false
    use Bond

    @pre all_positive: forall(row <- matrix, forall(c <- row, c > 0))
    def f(matrix), do: matrix
  end

  describe "nested quantifiers (documented best-effort: outermost element wins)" do
    test "reports the outermost failing element, not the inner one" do
      error = assert_raise Bond.PreconditionError, fn -> NestedFixture.f([[1, 2], [3, -4]]) end

      # The side channel is last-write, so the OUTER row is reported (not the inner `-4`).
      # This pins the documented v1 limitation.
      assert Exception.message(error) =~
               "counterexample: element at index 1 ([3, -4]) does not satisfy " <>
                 "`forall(c <- row, c > 0)`"
    end
  end

  describe "telemetry" do
    @event [:bond, :assertion, :failure]

    def forward(name, measurements, metadata, pid) do
      send(pid, {:telemetry, name, measurements, metadata})
    end

    test "failure event metadata carries the :quantifier detail" do
      handler_id = "quantifier-telemetry-#{System.unique_integer([:positive])}"
      :ok = :telemetry.attach(handler_id, @event, &__MODULE__.forward/4, self())
      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert_raise Bond.PreconditionError, fn -> PreFixture.scale([1, -9]) end

      assert_receive {:telemetry, @event, _measurements, metadata}

      assert metadata.quantifier == %{
               quantifier: :forall,
               element: -9,
               index: 1,
               predicate: "x > 0"
             }
    end
  end

  describe "generator-syntax guard" do
    test "forall without a `pattern <- enumerable` generator raises a clear error" do
      error =
        assert_raise ArgumentError, fn ->
          Code.eval_string("""
          defmodule Bond.QuantifiedAssertionsTest.BadForall do
            use Bond
            @pre bad: forall(items, x > 0)
            def f(items), do: items
          end
          """)
        end

      assert Exception.message(error) =~ "forall/2 expects a generator"
    end

    test "for-style multiple generators raise a clear error pointing at nesting" do
      error =
        assert_raise ArgumentError, fn ->
          Code.eval_string("""
          defmodule Bond.QuantifiedAssertionsTest.MultiGen do
            use Bond
            @pre bad: forall(x <- xs, y <- ys, x < y)
            def f(xs, ys), do: {xs, ys}
          end
          """)
        end

      message = Exception.message(error)
      assert message =~ "forall/3 is not supported"
      assert message =~ "do not accept multiple generators or filters"
      assert message =~ "forall(x <- xs, forall(y <- ys, predicate))"
    end

    test "exists with multiple generators raises the same shape of error" do
      error =
        assert_raise ArgumentError, fn ->
          Code.eval_string("""
          defmodule Bond.QuantifiedAssertionsTest.MultiGenExists do
            use Bond
            @pre bad: exists(x <- xs, y <- ys, x < y)
            def f(xs, ys), do: {xs, ys}
          end
          """)
        end

      assert Exception.message(error) =~ "exists/3 is not supported"
    end
  end
end
