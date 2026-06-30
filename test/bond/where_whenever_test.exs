defmodule Bond.WhereWheneverTest do
  @moduledoc """
  Behaviour tests for the `where`/`whenever` destructuring binding forms (#47) on `@pre`/`@post`.

  Diagnostics (arrow/keyword mismatch, empty body, …) live in
  `Bond.AssertionSyntaxErrorsTest`; doc rendering lives in its own test.
  """
  use ExUnit.Case, async: true

  describe "@post whenever (conditional, <-)" do
    defmodule Conditional do
      use Bond
      import Bond.Predicates

      @post whenever({:ok, %{keys: keys}} <- result),
        nonempty: keys != [],
        has_a: exists(k <- keys, k == "a")
      def run(:ok, input), do: {:ok, %{keys: input}}
      def run(:err, _input), do: {:error, :nope}
    end

    test "matching shape with satisfied members passes" do
      assert {:ok, %{keys: ["a", "b"]}} = Conditional.run(:ok, ["a", "b"])
    end

    test "non-matching shape is vacuously satisfied" do
      assert {:error, :nope} = Conditional.run(:err, [])
    end

    test "matching shape with a violated member raises, attributed to that member" do
      error = assert_raise Bond.PostconditionError, fn -> Conditional.run(:ok, ["x"]) end
      assert error.expression =~ "exists"
      assert error.label == :has_a
    end
  end

  describe "@post where (assert, =)" do
    defmodule Assert do
      use Bond

      @post where({:noreply, %{n: n}} = result),
        integer: is_integer(n),
        pos: n > 0
      def run(n) when is_integer(n), do: {:noreply, %{n: n}}
      def run(:wrong_shape), do: :nope
    end

    test "matching shape with satisfied members passes" do
      assert {:noreply, %{n: 5}} = Assert.run(5)
    end

    test "matching shape with a violated member raises, attributed to that member" do
      error = assert_raise Bond.PostconditionError, fn -> Assert.run(-1) end
      assert error.label == :pos
    end

    test "a non-matching shape is itself a violation (the :shape failure)" do
      error = assert_raise Bond.PostconditionError, fn -> Assert.run(:wrong_shape) end
      assert error.label == :shape
      assert error.expression =~ "{:noreply, %{n: n}} = result"
    end
  end

  describe "bound names use Bond's full assertion syntax (the motivating gap)" do
    defmodule Nested do
      use Bond
      import Bond.Predicates

      # A value buried in a list-in-a-map-in-a-tuple, asserted with `exists` — impossible
      # via a `<~` guard today.
      @post where({:noreply, %{keys: new_keys, timer: timer}} = result),
        timer_ref: is_reference(timer),
        has_target: exists(k <- new_keys, k.key == "a")
      def cast(keys) do
        timer = Process.send_after(self(), :tick, 1_000)
        {:noreply, %{keys: Enum.map(keys, &%{key: &1}), timer: timer}}
      end
    end

    test "passes when the nested key is present" do
      assert {:noreply, %{}} = Nested.cast(["a", "b"])
    end

    test "fails when the nested key is absent" do
      error = assert_raise Bond.PostconditionError, fn -> Nested.cast(["b", "c"]) end
      assert error.label == :has_target
    end
  end

  describe "case analysis via one whenever per shape" do
    defmodule CaseAnalysis do
      use Bond

      @post whenever({:ok, v} <- result), ok_pos: v > 0
      @post whenever({:error, reason} <- result), known: reason in [:timeout, :refused]
      def run(:good), do: {:ok, 42}
      def run(:bad_ok), do: {:ok, -1}
      def run(:known_err), do: {:error, :timeout}
      def run(:weird_err), do: {:error, :surprise}
    end

    test "each clause checks only its own shape" do
      assert {:ok, 42} = CaseAnalysis.run(:good)
      assert {:error, :timeout} = CaseAnalysis.run(:known_err)
    end

    test "the ok-clause fires on a bad ok value" do
      assert_raise Bond.PostconditionError, fn -> CaseAnalysis.run(:bad_ok) end
    end

    test "the error-clause fires on an unknown reason" do
      assert_raise Bond.PostconditionError, fn -> CaseAnalysis.run(:weird_err) end
    end
  end

  describe "bare / labelled / mixed scoped assertions" do
    defmodule Shapes do
      use Bond

      @post where({:ok, x} = result), is_list(x)
      def bare(x), do: {:ok, x}

      @post where({:ok, x} = result), listy: is_list(x), nonempty: x != []
      def labelled(x), do: {:ok, x}

      @post(where({:ok, x} = result), is_list(x), nonempty: x != [])
      def mixed(x), do: {:ok, x}
    end

    test "bare assertion works (no label required)" do
      assert {:ok, [1]} = Shapes.bare([1])
      assert_raise Bond.PostconditionError, fn -> Shapes.bare(:notlist) end
    end

    test "labelled assertions work" do
      assert {:ok, [1]} = Shapes.labelled([1])
      err = assert_raise Bond.PostconditionError, fn -> Shapes.labelled([]) end
      assert err.label == :nonempty
    end

    test "mixed bare + labelled works" do
      assert {:ok, [1]} = Shapes.mixed([1])
      assert_raise Bond.PostconditionError, fn -> Shapes.mixed([]) end
    end
  end

  describe "@pre where/whenever binds from arguments" do
    defmodule Pre do
      use Bond

      @pre where({:user, %{age: age}} = subject), adult: age >= 18
      def greet(subject), do: (fn {:user, %{age: _}} -> :ok end).(subject)
    end

    test "passes when the precondition holds" do
      assert :ok = Pre.greet({:user, %{age: 21}})
    end

    test "fails when a scoped precondition is violated" do
      error = assert_raise Bond.PreconditionError, fn -> Pre.greet({:user, %{age: 12}}) end
      assert error.label == :adult
    end
  end

  describe "generated documentation renders binding groups" do
    defp fetch_fun_doc(mod, fun, arity) do
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(mod)

      Enum.find_value(docs, fn
        {{:function, ^fun, ^arity}, _, _, %{"en" => doc}, _} -> doc
        _ -> nil
      end)
    end

    test "whenever renders a 'matches' header with indented members" do
      doc = fetch_fun_doc(BondTest.WhereWheneverDocs, :run, 1)

      assert doc =~ "#### Postconditions"
      assert doc =~ "whenever result matches {:ok, %{urls: urls}}:"
      assert doc =~ "url_count: length(urls) > 0"
      assert doc =~ "all_https: forall(u <- urls, String.starts_with?(u, \"https\"))"
    end

    test "where renders an 'is' header" do
      doc = fetch_fun_doc(BondTest.WhereWheneverDocs, :run, 1)

      assert doc =~ "where result is {:ok, payload}:"
      assert doc =~ "tagged: is_map(payload)"
    end
  end

  describe "multi-clause function binding the source from an argument" do
    defmodule MultiClause do
      use Bond

      # Multi-clause: the lifted defp takes canonical bare params, so the binding source `env`
      # must be recognised as a referenced parameter or it would be dropped from the defp.
      @pre whenever({:ok, %{level: level}} <- env), bounded: level in 0..10
      def configure(:a, env), do: env
      def configure(:b, env), do: env
    end

    test "the source argument is available to the lifted precondition defp" do
      assert {:ok, %{level: 3}} = MultiClause.configure(:a, {:ok, %{level: 3}})
      assert :skip = MultiClause.configure(:b, :skip)
    end

    test "a scoped precondition still fires across clauses" do
      assert_raise Bond.PreconditionError, fn ->
        MultiClause.configure(:b, {:ok, %{level: 99}})
      end
    end
  end

  describe "@invariant where/whenever (binds from `subject`)" do
    defmodule Bag do
      use Bond
      import Bond.Predicates
      defstruct items: []

      @invariant(where(%Bag{items: items} = subject),
        listy: is_list(items),
        no_nil: forall(i <- items, not is_nil(i))
      )
      def make(list), do: %Bag{items: list}
    end

    test "passes for a valid struct" do
      assert %Bag{items: [1, 2]} = Bag.make([1, 2])
    end

    test "fires on the returned struct when a member is violated" do
      error = assert_raise Bond.InvariantError, fn -> Bag.make([1, nil]) end
      assert error.label == :no_nil
    end
  end

  describe "@state_invariant / @transition_invariant where/whenever (Bond.Server)" do
    defmodule Server do
      use GenServer
      use Bond.Server
      import Bond.Predicates

      @state_invariant(where(%{count: count, items: items} = state),
        non_neg: count >= 0,
        counted: length(items) == count
      )

      @transition_invariant(whenever(%{count: oc} <- old_state),
        monotonic: new_state.count >= oc
      )

      def init(c), do: {:ok, %{count: c, items: []}}
    end

    test "state invariant passes for a consistent state" do
      assert :ok = Server.__bond_state_invariant_check__(%{count: 0, items: []})
    end

    test "state invariant member violation throws an :assertion_failure" do
      assert {:assertion_failure, %{kind: :state_invariant, label: :counted}} =
               catch_throw(Server.__bond_state_invariant_check__(%{count: 1, items: []}))
    end

    test "a `where` (=) state shape mismatch is a :shape violation" do
      assert {:assertion_failure, %{kind: :state_invariant, label: :shape}} =
               catch_throw(Server.__bond_state_invariant_check__(:not_a_map))
    end

    test "transition invariant fires on a violated member" do
      assert :ok = Server.__bond_transition_invariant_check__(%{count: 1}, %{count: 2})

      assert {:assertion_failure, %{kind: :transition_invariant, label: :monotonic}} =
               catch_throw(Server.__bond_transition_invariant_check__(%{count: 5}, %{count: 2}))
    end

    test "a `whenever` (<-) transition is vacuous when old_state doesn't match" do
      assert :ok = Server.__bond_transition_invariant_check__(:no_prior, %{count: 2})
    end
  end

  describe "conditional compilation" do
    defmodule Purged do
      # Purging postconditions requires purging invariants too (the pre ≤ post ≤ inv chain).
      use Bond, postconditions: :purge, invariants: :purge

      @post where({:ok, x} = result), pos: x > 0
      def f(x), do: {:ok, x}
    end

    test "a purged @post where/whenever is compiled out (no check at runtime)" do
      assert {:ok, -1} = Purged.f(-1)
    end
  end
end
