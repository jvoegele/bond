defmodule BondTest.RemoteCallAssertions do
  @moduledoc """
  Fixture exercising remote-function-call expressions as the outermost form of
  `@pre`, `@post`, `@invariant`, and `check/1` assertions. Pre-0.16.2 these
  were rejected by `Bond.Compiler.Assertion.is_assertion_expression/1` because
  the outer AST shape is `{{:., _, _}, _, _}` rather than `{atom, _, _}`.

  Each function below uses a remote call as the *bare* form of an assertion
  (no `== true` wrapping). If the assertion AST guard rejects any of these,
  the module fails to compile.
  """

  # Most public functions in this fixture deliberately don't operate on the
  # struct — the @invariant exists for the `push_atom/2` case alone, and the
  # other defs (greet/1, squares/1, fetch_id/1, inline_check_example/1) are
  # remote-call-assertion fixtures whose subjects are non-struct values.
  # Suppress the per-function "no struct parameter matched" warning here.
  use Bond, warn_skipped_invariants: false

  defstruct [:items]

  @pre String.starts_with?(name, "user-")
  def greet(name), do: "hello, " <> name

  @post Enum.all?(result, &is_integer/1)
  def squares(n) when is_integer(n) and n >= 0 do
    Enum.map(0..n, fn x -> x * x end)
  end

  @pre Map.has_key?(map, :id)
  def fetch_id(map), do: Map.fetch!(map, :id)

  @invariant Enum.all?(subject.items, &is_atom/1)
  def push_atom(%__MODULE__{} = s, atom) when is_atom(atom) do
    %{s | items: [atom | s.items]}
  end

  def inline_check_example(xs) do
    check List.first(xs) != nil
    xs
  end
end
