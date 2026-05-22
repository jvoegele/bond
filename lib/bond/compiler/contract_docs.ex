defmodule Bond.Compiler.ContractDocs do
  @moduledoc internal: true
  @moduledoc """
  Builds the `@doc` clauses for a contract-augmented function — the user's original
  `@doc` (if any) plus auto-generated `#### Preconditions` / `#### Postconditions`
  sections.

  Lives in its own module (rather than as private functions inside
  `Bond.Compiler.AnnotatedFunction`) for the same compile-order reason `Invariants`
  was extracted: `AnnotatedFunction.new/1` is called by `Bond.Compiler.CompileStateFSM`
  at user-module compile time, so the smaller `AnnotatedFunction` stays the more
  reliably it finishes compiling before the test-support and other client modules
  start their own. Doc-generation is a self-contained ~80 lines that's only consumed
  by `apply_contract/2`, so it's the cheapest mass to shed.
  """

  alias Bond.Compiler.AnnotatedFunction

  @doc """
  Returns the list of quoted `Module.put_attribute(__MODULE__, :doc, ...)` expressions
  that the override clause splices into the user module. Each expression re-emits one of
  the user's `@doc` attributes, with the auto-generated `#### Preconditions` /
  `#### Postconditions` sections appended (filtered by the per-kind mode).

  When the user did not write a `@doc` themselves but the function has contracts, a
  synthetic doc string is created so the contracts still appear in generated
  documentation.
  """
  @spec doc_clauses(
          AnnotatedFunction.t(),
          Macro.Env.t(),
          AnnotatedFunction.mode(),
          AnnotatedFunction.mode()
        ) :: [Macro.t()]
  def doc_clauses(
        %AnnotatedFunction{doc_attributes: doc_attributes} = annotated_function,
        env,
        pre_mode,
        post_mode
      ) do
    contract_docs = build_contract_docs(annotated_function, pre_mode, post_mode)

    has_string_doc? = Enum.any?(doc_attributes, fn {_meta, value} -> is_binary(value) end)

    augmented =
      cond do
        has_string_doc? ->
          Enum.map(doc_attributes, fn
            {meta, value} when is_binary(value) and contract_docs != "" ->
              {meta, value <> "\n\n" <> contract_docs}

            other ->
              other
          end)

        contract_docs != "" ->
          # No user-supplied string doc; synthesise one containing just the contract docs so
          # the contracts always appear in generated documentation.
          [{[line: env.line], contract_docs} | doc_attributes]

        true ->
          doc_attributes
      end

    for {meta, value} <- augmented do
      line = Keyword.get(meta, :line, env.line)

      quote do
        Module.put_attribute(__MODULE__, :doc, {unquote(line), unquote(Macro.escape(value))})
      end
    end
  end

  defp build_contract_docs(
         %AnnotatedFunction{preconditions: preconditions, postconditions: postconditions},
         pre_mode,
         post_mode
       ) do
    precondition_docs =
      if pre_mode != :purge,
        do: generate_assertion_docs(preconditions, header: "#### Preconditions"),
        else: []

    postcondition_docs =
      if post_mode != :purge,
        do: generate_assertion_docs(postconditions, header: "#### Postconditions"),
        else: []

    contract_iodata =
      case {Enum.empty?(precondition_docs), Enum.empty?(postcondition_docs)} do
        {true, true} -> []
        {true, false} -> postcondition_docs
        {false, true} -> precondition_docs
        {false, false} -> [precondition_docs, "\n\n", postcondition_docs]
      end

    IO.iodata_to_binary(contract_iodata)
  end

  defp generate_assertion_docs([], _opts), do: []

  defp generate_assertion_docs(assertions, opts) do
    header = if header = opts[:header], do: header <> "\n\n", else: ""

    assertions
    |> Enum.reduce([], fn
      %{label: nil, code: code}, acc ->
        [code | acc]

      assertion, acc ->
        label = assertion.label |> inspect() |> String.trim_leading(":")
        [[label, ": ", assertion.code] | acc]
    end)
    |> Enum.reverse()
    |> List.insert_at(0, header)
    |> Enum.intersperse("\n    ")
  end
end
