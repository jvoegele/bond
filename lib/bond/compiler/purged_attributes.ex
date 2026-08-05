defmodule Bond.Compiler.PurgedAttributes do
  @moduledoc internal: true
  @moduledoc """
  Keeps module attributes read *only* by a purged contract from warning as unused (#79).

  A contract is often the only reader of a constant:

      @limit 10
      @pre within: n <= @limit
      def bounded(n), do: n

  Compile that with `preconditions: :purge` and Bond discards the assertion, `@limit`
  loses its last reader, and Elixir warns "module attribute @limit was set but never
  used". Clean in dev, noisy in exactly the build people gate on `--warnings-as-errors`,
  and the warning says nothing about Bond, so there is no path from it back to the cause.

  The fix is to read the attribute during compilation rather than to emit code:
  `Module.get_attribute/2` counts as a use, so the warning goes away without a byte
  reaching the BEAM. That is cheaper and safer than the alternative of emitting `_ = @attr`
  into the module body, which has to be placed where the attribute is in scope and must
  avoid warning on its own account.
  """

  @doc """
  Reads every module attribute the given ASTs reference, so a purged contract still
  counts as a reader.

  Only attributes the module actually has are read: an assertion mentioning an attribute
  that was never set would, in a *non*-purged build, fail at expansion time anyway, and
  reading a missing one here would trade the unused warning for an undefined one.

  Bond's own bookkeeping attributes are skipped — they are set and read by the compiler,
  never by an assertion, so seeing one here would mean something else has gone wrong.
  """
  @spec consume(module(), [Macro.t()]) :: :ok
  def consume(module, asts) when is_list(asts) do
    asts
    |> Enum.flat_map(&attribute_reads/1)
    |> Enum.uniq()
    |> Enum.each(fn name ->
      if Module.has_attribute?(module, name), do: Module.get_attribute(module, name)
    end)

    :ok
  end

  @doc """
  The module attributes an AST *reads*, in source order.

  A read is `{:@, _, [{name, _, context}]}` where the context is not a list; an attribute
  *write* carries the value as a single-element list there, and is not a read.
  """
  @spec attribute_reads(Macro.t()) :: [atom()]
  def attribute_reads(ast) do
    {_ast, names} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{name, _, context}]} = node, acc when is_atom(name) and not is_list(context) ->
          if bond_internal?(name), do: {node, acc}, else: {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    names |> Enum.reverse() |> Enum.uniq()
  end

  defp bond_internal?(name) do
    name |> Atom.to_string() |> String.starts_with?(["__bond", "bond_"])
  end
end
