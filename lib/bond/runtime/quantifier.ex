defmodule Bond.Runtime.Quantifier do
  @moduledoc internal: true

  @moduledoc """
  Runtime support for the `forall`/`exists` quantified-assertion macros defined in
  `Bond.Predicates`.

  Each quantifier returns a plain `boolean()` so it composes with the ordinary boolean
  assertion operators (`and`, `or`, `not`, `~>`, `|||`) and keeps Bond's Dialyzer-laundering
  path intact — a spec'd `boolean()` cannot be narrowed to `true`, so the falsy branch of the
  surrounding `Bond.Runtime.Eval.check_assertion/3` stays reachable (see
  `Bond.Predicates.__truthy__/1` for the same concern on `~>`).

  The *element-level* failure detail — which element/index violated `forall`, or that no
  element satisfied `exists` — cannot ride back through that boolean, so it travels through a
  single per-process side channel that `Bond.Runtime.Eval` reads on the failure path.

  ## Side-channel lifecycle

  The slot (`@failure_key`) holds at most one failure-detail map, scoped to a single assertion
  expression:

    * every quantifier call clears the slot on entry and writes detail only when it fails;
    * `Bond.Runtime.Eval.check_assertion/3` and `check_value/3` clear the slot whenever an
      assertion *passes*, so a quantifier whose `false` was absorbed into a truthy result
      (`not forall(...)`, `forall(...) or other`) cannot leak stale detail into a later
      assertion's failure;
    * `Bond.Runtime.Eval` pops the slot when an assertion fails, attaching the detail under the
      `:quantifier` key of the failure info.

  When several quantifiers appear in one expression — including nested ones — the slot holds
  the *last* one to fail. This is a documented best-effort limitation; for the motivating
  bare-quantifier case (`@pre forall(x <- items, x > 0)`) the reported element is exact.
  """

  # Single per-process slot carrying the most recent quantifier failure detail. Read and
  # cleared by `Bond.Runtime.Eval` on the assertion failure/success paths via `pop/0`/`clear/0`.
  @failure_key :__bond_quantifier_failure__

  @typedoc """
  Failure detail recorded in the side channel and surfaced on the `:quantifier` key of an
  assertion failure.

  The `:kind` field distinguishes the two ways a quantifier can fail: `:predicate` — an element
  matched the generator pattern but the predicate was falsy; `:pattern` — an element did not
  match the generator pattern at all (only possible for a structural pattern, which emits a
  `:no_match` catch-all; see `Bond.Predicates`).

  `:forall` carries the offending `:element` and zero-based `:index`. `:exists` carries the
  element `:count` and the source text of the enumerable; a `:pattern`-kind `:exists` failure
  means *no* element matched the generator pattern.
  """
  @type failure ::
          %{
            quantifier: :forall,
            kind: :predicate,
            element: term(),
            index: non_neg_integer(),
            predicate: String.t()
          }
          | %{
              quantifier: :forall,
              kind: :pattern,
              element: term(),
              index: non_neg_integer(),
              pattern: String.t()
            }
          | %{
              quantifier: :exists,
              kind: :predicate,
              predicate: String.t(),
              count: non_neg_integer(),
              enum_code: String.t()
            }
          | %{
              quantifier: :exists,
              kind: :pattern,
              pattern: String.t(),
              count: non_neg_integer(),
              enum_code: String.t()
            }

  @doc """
  Universal quantifier: returns `true` when `fun` holds for *every* element of `enum`.

  Short-circuits at the first element for which `fun` returns falsy, recording that element and
  its zero-based index in the side channel before returning `false`. An empty `enum` is
  vacuously `true`. `predicate_code` is the source text of the predicate (captured at
  compile-time by the `Bond.Predicates.forall/2` macro) for the failure message.

  A predicate that *raises* (rather than returning falsy) propagates unchanged — the quantifier
  reports an unsatisfied element, not a crashing one. Guard shape-dependent predicates with the
  `~>` implication operator, exactly as in multi-clause contracts.

  `fun` returns `{:match, predicate_result}` for an element that matched the generator pattern,
  or `:no_match` for one that did not (structural patterns only — see `Bond.Predicates`). A
  `:no_match` element makes the universal fail with a `:pattern`-kind counterexample;
  `predicate_code` and `pattern_code` are the compile-time source texts for the message.
  """
  @spec forall(
          Enumerable.t(),
          (term() -> {:match, as_boolean(term())} | :no_match),
          String.t(),
          String.t()
        ) :: boolean()
  def forall(enum, fun, predicate_code, pattern_code) when is_function(fun, 1) do
    clear()

    result =
      enum
      |> Stream.with_index()
      |> Enum.reduce_while(true, fn {element, index}, _acc ->
        case fun.(element) do
          {:match, truthy} when truthy in [false, nil] -> {:halt, {:unsatisfied, element, index}}
          {:match, _truthy} -> {:cont, true}
          :no_match -> {:halt, {:no_match, element, index}}
        end
      end)

    case result do
      true ->
        true

      {:unsatisfied, element, index} ->
        put(%{
          quantifier: :forall,
          kind: :predicate,
          element: element,
          index: index,
          predicate: predicate_code
        })

        false

      {:no_match, element, index} ->
        put(%{
          quantifier: :forall,
          kind: :pattern,
          element: element,
          index: index,
          pattern: pattern_code
        })

        false
    end
  end

  @doc """
  Existential quantifier: returns `true` when `fun` holds for *at least one* element of `enum`.

  Short-circuits at the first element for which `fun` returns truthy. If no element satisfies
  `fun` (including an empty `enum`), records the element count and returns `false`. There is no
  single offending element, so the failure detail carries `:count` and `enum_code` (the source
  text of the enumerable) for a "no element of … satisfies …" message.

  `fun` returns `{:match, predicate_result}` or `:no_match`, as in `forall/4`. When *every*
  element failed to match the generator pattern (and there was at least one), the failure is
  reported as a `:pattern`-kind "no element matches pattern …" rather than the misleading "no
  element satisfies …"; a mix of shapes falls back to the predicate message.
  """
  @spec exists(
          Enumerable.t(),
          (term() -> {:match, as_boolean(term())} | :no_match),
          String.t(),
          String.t(),
          String.t()
        ) :: boolean()
  def exists(enum, fun, predicate_code, enum_code, pattern_code) when is_function(fun, 1) do
    clear()

    result =
      Enum.reduce_while(enum, {0, 0}, fn element, {checked, mismatches} ->
        case fun.(element) do
          {:match, truthy} when truthy in [false, nil] -> {:cont, {checked + 1, mismatches}}
          {:match, _truthy} -> {:halt, :found}
          :no_match -> {:cont, {checked + 1, mismatches + 1}}
        end
      end)

    case result do
      :found ->
        true

      {count, mismatches} when count > 0 and mismatches == count ->
        put(%{
          quantifier: :exists,
          kind: :pattern,
          pattern: pattern_code,
          count: count,
          enum_code: enum_code
        })

        false

      {count, _mismatches} ->
        put(%{
          quantifier: :exists,
          kind: :predicate,
          predicate: predicate_code,
          count: count,
          enum_code: enum_code
        })

        false
    end
  end

  @doc """
  Reads and clears the current quantifier failure detail, returning it or `nil`.

  Called by `Bond.Runtime.Eval` on the assertion-failure path to attach element-level detail to
  the failure info.
  """
  @spec pop() :: failure() | nil
  def pop, do: Process.delete(@failure_key)

  @doc """
  Clears the side channel.

  Called by `Bond.Runtime.Eval` whenever an assertion passes, so an absorbed quantifier failure
  cannot leak into a later assertion's failure, and by each quantifier on entry.
  """
  @spec clear() :: :ok
  def clear do
    Process.delete(@failure_key)
    :ok
  end

  @spec put(failure()) :: :ok
  defp put(detail) when is_map(detail) do
    Process.put(@failure_key, detail)
    :ok
  end
end
