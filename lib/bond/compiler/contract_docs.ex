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
  # Private functions can't carry @doc — Elixir warns "module attribute @doc was
  # set but never used" / "@doc is always discarded for private functions". Skip
  # emission entirely for `defp` so contracts on private helpers don't generate
  # warnings at the user's call site.
  def doc_clauses(%AnnotatedFunction{kind: :defp}, _env, _pre_mode, _post_mode), do: []

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

    lines =
      assertions
      |> Enum.chunk_by(fn assertion -> assertion.binding && assertion.binding.group_id end)
      |> Enum.flat_map(fn
        [%{binding: nil} | _] = singles -> Enum.map(singles, &assertion_doc_line/1)
        [%{binding: binding} | _] = group -> binding_group_doc_lines(binding, group)
      end)

    [header | lines] |> Enum.intersperse("\n    ")
  end

  # One documentation line for an assertion: the rendered `code`, prefixed with `label: ` when
  # labelled.
  defp assertion_doc_line(%{label: nil, code: code}), do: code
  defp assertion_doc_line(%{label: label, code: code}), do: [label_string(label), ": ", code]

  # A `where`/`whenever` binding group (#47): a header naming the binding, then its members
  # indented one extra level beneath it.
  defp binding_group_doc_lines(binding, members) do
    member_lines = Enum.map(members, fn member -> ["  ", assertion_doc_line(member)] end)
    [binding_doc_header(binding) | member_lines]
  end

  # "where <source> is <pattern>:" (assert) or "whenever <source> matches <pattern>:"
  # (conditional) — the leading keyword carries the semantics, matching the source.
  defp binding_doc_header(%{mode: :assert, pattern: pattern, source: source}) do
    ["where ", Macro.to_string(source), " is ", Macro.to_string(pattern), ":"]
  end

  defp binding_doc_header(%{mode: :conditional, pattern: pattern, source: source}) do
    ["whenever ", Macro.to_string(source), " matches ", Macro.to_string(pattern), ":"]
  end

  defp label_string(label), do: label |> inspect() |> String.trim_leading(":")

  @doc """
  Returns a markdown section documenting a module's `@invariant` declarations,
  suitable for appending to the module's `@moduledoc`. Returns `nil` when the
  module has no invariants or when invariants are `:purge`d (the docs follow
  the same suppression rule as per-function contract docs).

  The section includes:

    * A preamble naming the struct module and explaining the implicit
      `subject` binding (so readers landing on the moduledoc without prior
      Bond context can read the invariants).
    * A code block listing each invariant in the same `label: expression`
      format used by per-function contract docs.
    * A footer noting when invariants fire and the `defp` exemption.
  """
  @spec moduledoc_invariants_section(
          [Bond.Compiler.Assertion.t(:invariant)],
          module(),
          AnnotatedFunction.mode()
        ) :: String.t() | nil
  def moduledoc_invariants_section([], _module, _mode), do: nil
  def moduledoc_invariants_section(_invariants, _module, :purge), do: nil

  def moduledoc_invariants_section(invariants, module, _mode) when is_list(invariants) do
    struct_ref = "%#{inspect(module)}{}"

    invariant_lines =
      invariants
      |> Enum.chunk_by(fn invariant -> invariant.binding && invariant.binding.group_id end)
      |> Enum.flat_map(fn
        [%{binding: nil} | _] = singles ->
          Enum.map(singles, &format_invariant_line/1)

        [%{binding: binding} | _] = group ->
          header = IO.iodata_to_binary(binding_doc_header(binding))
          [header | Enum.map(group, fn member -> "  " <> format_invariant_line(member) end)]
      end)
      |> Enum.map(&("    " <> &1))
      |> Enum.join("\n")

    """
    ## Invariants

    Bond ensures the following invariants hold for every value of `#{struct_ref}` produced
    by or passed into this module's public API. Inside each assertion, `subject` refers
    to the value being checked.

    #{invariant_lines}

    These invariants are checked automatically on entry to and exit from every public
    function in this module. Private functions are exempt by the Eiffel convention.\
    """
  end

  defp format_invariant_line(%{label: nil, code: code}), do: code

  defp format_invariant_line(%{label: label, code: code}) do
    label_str = label |> inspect() |> String.trim_leading(":")
    "#{label_str}: #{code}"
  end
end
