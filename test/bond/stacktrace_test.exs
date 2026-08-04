defmodule Bond.StacktraceTest do
  @moduledoc """
  Regression tests for #75: adding `use Bond` must not degrade the diagnostics of
  *ordinary* errors in a contracted module.

  A `FunctionClauseError` is far more common in a working codebase than a
  contract violation, so a library whose value proposition is better diagnostics
  cannot afford to make that one worse. Before the fix, a no-matching-clause call
  into a contracted function raised with **no file/line at all** and reported a
  compiler-internal `-inlined-count/1-` name.

  The cause was not the clause wrapper's `quote` lacking a position — adding
  `quote file: ..., line: ...` there changes nothing. Elixir marks AST returned
  from a `@before_compile` callback as `generated: true` with `location: 0`
  unless the node already carries an explicit `:line`, and a `generated: true`
  clause is both position-less and a candidate for the Erlang inliner. Setting
  `:line` on the `def` node is what prevents the marking.
  """

  use ExUnit.Case, async: true

  alias BondTest.Stacktrace.Guarded
  alias BondTest.Stacktrace.MultiClause
  alias BondTest.Stacktrace.PreFails
  alias BondTest.Stacktrace.SingleClause
  alias BondTest.Stacktrace.Uncontracted
  alias BondTest.Stacktrace.WithInvariant

  # Calls through `apply/3` deliberately. These calls pass arguments that match no
  # clause, which is the whole point — but now that the wrapper carries a real
  # position, Elixir's type checker can see the clause types and (correctly, and
  # exactly as it does for an uncontracted module) flags a direct call as
  # incompatible. Going through `apply/3` keeps the test's intent without
  # generating a compile-time warning the suite would then have to tolerate.
  defp top_frame(module, fun, args) do
    apply(module, fun, args)
    flunk("expected a FunctionClauseError from #{inspect(module)}.#{fun}/#{length(args)}")
  rescue
    FunctionClauseError ->
      [frame | _] = __STACKTRACE__
      frame
  end

  describe "FunctionClauseError in a contracted module" do
    test "carries the file and line of the user's first clause (multi-clause)" do
      {module, fun, _arity_or_args, location} = top_frame(MultiClause, :count, [5])

      assert module == MultiClause
      assert fun == :count
      assert location[:line] == MultiClause.first_clause_line()
      assert location[:file] |> to_string() =~ "stacktrace.ex"
    end

    test "carries the file and line for a single-clause function" do
      {module, fun, _args, location} = top_frame(SingleClause, :count, [5])

      assert module == SingleClause
      assert fun == :count
      assert location[:line] == SingleClause.first_clause_line()
    end

    test "carries the file and line for a guarded function" do
      {module, fun, _args, location} = top_frame(Guarded, :classify, [:nope])

      assert module == Guarded
      assert fun == :classify
      assert location[:line] == Guarded.first_clause_line()
    end

    test "carries the file and line for an invariant-declaring module" do
      {module, fun, _args, location} = top_frame(WithInvariant, :bump, [:nope])

      assert module == WithInvariant
      assert fun == :bump
      assert location[:line] == WithInvariant.first_clause_line()
    end

    test "reports the user's function name, not a compiler-internal one" do
      # Was `MultiClause."-inlined-count/1-"/1` — the Erlang compiler inlining
      # the position-less `generated: true` wrapper.
      {_module, fun, _args, _location} = top_frame(MultiClause, :count, [5])

      refute to_string(fun) =~ "inlined"
      refute to_string(fun) =~ "bond"
      assert fun == :count
    end

    test "the message names the user's function, not a compiler-internal one" do
      message =
        try do
          apply(MultiClause, :count, [5])
        rescue
          e in FunctionClauseError -> Exception.message(e)
        end

      assert message =~ "MultiClause.count/1"
      refute message =~ "inlined"
    end
  end

  describe "parity with an uncontracted module" do
    test "a contracted module reports the same frame shape as a plain one" do
      contracted = top_frame(MultiClause, :count, [5])
      plain = top_frame(Uncontracted, :count, [5])

      {_m1, fun1, _a1, loc1} = contracted
      {_m2, fun2, _a2, loc2} = plain

      # Same function name, and both point at their own first clause in this file.
      assert fun1 == fun2
      assert loc1[:line] == MultiClause.first_clause_line()
      assert loc2[:line] == Uncontracted.first_clause_line()
      assert to_string(loc1[:file]) == to_string(loc2[:file])
    end
  end

  describe "contract violations still report correctly" do
    test "a precondition violation still raises, and points at the user's source" do
      # This call matches the clause and fails `@pre`, so the contract path runs
      # rather than the no-matching-clause path.
      error =
        try do
          apply(PreFails, :double, [-1])
          flunk("expected a Bond.PreconditionError")
        rescue
          e in Bond.PreconditionError ->
            [frame | _] = __STACKTRACE__
            {e, frame}
        end

      {exception, {module, _fun, _args, location}} = error

      assert module == PreFails

      # The frame points into the user's own source with a real position — the
      # property #75 was about. It resolves to the module's `defmodule` line
      # rather than the failing function's, because the lifted precondition defp
      # is emitted at the module env's position; that is pre-existing and
      # separate from this fix. It matters little for contract violations, since
      # Bond's own error carries the precise location in its message.
      assert to_string(location[:file]) =~ "stacktrace.ex"
      assert is_integer(location[:line]) and location[:line] > 0

      assert Exception.message(exception) =~ "positive"
    end
  end
end
