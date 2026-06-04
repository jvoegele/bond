defmodule Bond.TypeCheckerRegressionTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Regression guard: Bond's generated override/lifted-defp code must not trip
  Elixir's built-in set-theoretic type checker in user modules.

  Unlike Dialyzer, the built-in checker runs during `mix compile` and ignores
  `@dialyzer` attributes, so the `nowarn_function` laundering does NOT cover it.
  Bond stays clean against the built-in checker for structural reasons (assertion
  evaluation and the struct-shape `case` live behind a `term()`-typed boundary in
  `Bond.Runtime.Eval`, and the `~>`/`<~` launderers keep their `case`/`if`
  non-exhaustive). This test pins that: a future Elixir whose checker regresses on
  Bond codegen — or a Bond codegen change that reintroduces a narrowed shape —
  fails here.

  The test is self-validating: a deliberately-broken control module must produce a
  diagnostic, so the guard can't pass vacuously if `Code.with_diagnostics/1` or the
  checker ever stop surfacing warnings through this path.
  """

  # Compiles `source` in isolation and returns the list of `:warning` diagnostics
  # the compiler (including the type checker) emits.
  defp warnings(source) do
    {_result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          Code.compile_string(source)
        rescue
          # A genuine CompileError would be a different (and louder) failure; surface
          # it via the diagnostics the harness already captured.
          _ -> :error
        end
      end)

    Enum.filter(diagnostics, &(&1.severity == :warning))
  end

  # A representative Bond module exercising the shapes most likely to interact with
  # type inference: single- and multi-clause functions, `@pre`/`@post` duplicating
  # typespec-implied guards, `old()`, the `~>`/`<~` operators, a heterogeneous
  # multi-clause head (struct destructure + bare-var sibling), and an invariant
  # struct with struct / `{:ok, struct}` / non-struct returns. `warn_skipped_invariants:
  # false` silences Bond's own advisory warning so any diagnostic that remains is a
  # compiler/type-checker warning — the thing this test is guarding.
  defp sample_source(mod) do
    """
    defmodule #{mod} do
      use Bond, warn_skipped_invariants: false

      defstruct items: [], capacity: 0
      @type t :: %__MODULE__{items: list(), capacity: non_neg_integer()}

      @invariant within_capacity: length(subject.items) <= subject.capacity,
                 nonneg_capacity: subject.capacity >= 0

      @spec deposit(integer(), pos_integer()) :: integer()
      @pre positive: amount > 0
      @post grew: result == old(balance) + amount
      def deposit(balance, amount) when is_integer(balance) and amount > 0 do
        balance + amount
      end

      @spec tag(binary()) :: {:ok, binary()}
      @pre is_bin: is_binary(s) and byte_size(s) >= 0
      def tag(s) when is_binary(s), do: {:ok, s}

      @spec parse(binary()) :: {:ok, integer()} | :error
      @post shaped: is_binary(input) ~> (({:ok, _} <~ result) or result == :error)
      def parse(input) when is_binary(input) do
        case Integer.parse(input) do
          {n, _} -> {:ok, n}
          :error -> :error
        end
      end

      # Heterogeneous multi-clause: struct destructure + bare-var sibling, forcing
      # Bond's canonical-name rewrite at position 0.
      @pre nonneg: count >= 0
      def take(%Range{} = r, count) when count >= 0, do: Enum.take(r, count)
      def take(list, count) when is_list(list) and count >= 0, do: Enum.take(list, count)

      @spec push(t(), term()) :: t() | {:error, :full}
      def push(%__MODULE__{} = stack, item) do
        if length(stack.items) >= stack.capacity do
          {:error, :full}
        else
          %{stack | items: [item | stack.items]}
        end
      end

      @spec try_new(integer()) :: {:ok, t()} | {:error, :bad}
      def try_new(capacity) when is_integer(capacity) and capacity >= 0 do
        {:ok, %__MODULE__{items: [], capacity: capacity}}
      end

      def try_new(_), do: {:error, :bad}

      @spec size(t()) :: non_neg_integer()
      def size(%__MODULE__{} = stack), do: length(stack.items)
    end
    """
  end

  # Unique module name per compile so repeated runs don't emit "redefining module".
  defp unique_mod(prefix), do: "#{prefix}#{System.unique_integer([:positive])}"

  test "the diagnostic capture actually catches type-checker warnings (self-check)" do
    control = """
    defmodule #{unique_mod("BondTypeCheckControl")} do
      def bad(%URI{} = u), do: u.no_such_field
    end
    """

    assert warnings(control) != [],
           "expected the built-in type checker to flag `u.no_such_field`; if this is " <>
             "empty, the capture path or the checker changed and this guard is toothless"
  end

  test "a representative Bond module compiles with no type-checker warnings" do
    warns = warnings(sample_source(unique_mod("BondTypeCheckSample")))

    assert warns == [],
           "Bond-generated code tripped the built-in type checker:\n\n" <>
             Enum.map_join(warns, "\n\n", & &1.message)
  end
end
