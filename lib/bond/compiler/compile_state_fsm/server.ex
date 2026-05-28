defmodule Bond.Compiler.CompileStateFSM.Server do
  @moduledoc false
  @behaviour :gen_statem

  # `require` (not `alias`) so Mix creates strong compile-time deps on both modules and
  # schedules them before this file. Without this, the parallel compiler on Elixir 1.19+
  # can race: the gen_statem event handler calls AnnotatedFunction.new/1 at user-module
  # compile time before AnnotatedFunction.beam has been written to disk.
  require Bond.Compiler.AnnotatedFunction, as: AnnotatedFunction
  require Bond.Compiler.FunctionDefinition, as: FunctionDefinition

  defstruct module: nil,
            last_mfa: nil,
            function_def_stack: [],
            annotated_function_stack: [],
            mfa_set: MapSet.new(),
            precondition_defs: [],
            postcondition_defs: [],
            invariant_defs: [],
            doc_attributes: [],
            functions_with_contracts: []

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init(module) when is_atom(module),
    do: {:ok, :no_contracts_pending, %__MODULE__{module: module}}

  @impl :gen_statem
  def handle_event({:call, from}, :get_state, state, data) do
    {:keep_state, data, [{:reply, from, state}]}
  end

  def handle_event({:call, _from}, _event, :error, _data) do
    raise "Bond.Compiler.CompileStateFSM is in an invalid state: :error"
  end

  def handle_event(:cast, _event, :error, _data) do
    raise "Bond.Compiler.CompileStateFSM is in an invalid state: :error"
  end

  def handle_event(:cast, _event, :done, data) do
    {:keep_state, data}
  end

  def handle_event({:call, from}, {:function_def, _function_def}, :done, data) do
    {:keep_state, data, {:reply, from, :ok}}
  end

  def handle_event({:call, from}, {:function_def, function_def}, state, data) do
    try do
      {state_transition, new_data, result} =
        if new_function_def?(function_def, data) do
          handle_new_function_def(function_def, state, data)
        else
          handle_function_clause(function_def, state, data)
        end

      case state_transition do
        :keep_state ->
          {:keep_state, new_data, {:reply, from, result}}

        {:next_state, next_state} ->
          {:next_state, next_state, new_data, {:reply, from, result}}
      end
    catch
      {:error, _reason} = error ->
        {:next_state, :error, clear_pending_contracts(data), {:reply, from, error}}
    end
  end

  def handle_event(:cast, {:precondition_def, precondition_def}, state, data)
      when state in [:no_contracts_pending, :contracts_pending] do
    new_data = update_in(data.precondition_defs, &[precondition_def | &1])
    {:next_state, :contracts_pending, new_data}
  end

  def handle_event(:cast, {:postcondition_def, postcondition_def}, state, data)
      when state in [:no_contracts_pending, :contracts_pending] do
    new_data = update_in(data.postcondition_defs, &[postcondition_def | &1])
    {:next_state, :contracts_pending, new_data}
  end

  # Invariants are module-scoped — they don't move the FSM into :contracts_pending (which
  # means "next def-event will absorb these"). They simply accumulate and are queried at
  # __before_compile__ time.
  def handle_event(:cast, {:invariant_def, invariant_def}, state, data)
      when state in [:no_contracts_pending, :contracts_pending] do
    new_data = update_in(data.invariant_defs, &[invariant_def | &1])
    {:keep_state, new_data}
  end

  def handle_event(:cast, {:doc_attribute, doc_value}, state, data)
      when state in [:no_contracts_pending, :contracts_pending] do
    new_data = update_in(data.doc_attributes, &[doc_value | &1])
    {:next_state, :contracts_pending, new_data}
  end

  def handle_event(:cast, :doc_attributes_applied, _state, data) do
    {:keep_state, clear_pending_doc_attributes(data)}
  end

  def handle_event({:call, from}, :module_defined, :contracts_pending, data) do
    error = {:error, "cannot define contracts that do not precede a function definition"}
    {:next_state, :error, clear_pending_contracts(data), {:reply, from, error}}
  end

  def handle_event({:call, from}, :module_defined, _state, data) do
    {:next_state, :done, clear_pending_contracts(data), {:reply, from, :ok}}
  end

  def handle_event({:call, from}, :pending_preconditions, :no_contracts_pending, data) do
    {:keep_state, data, {:reply, from, []}}
  end

  def handle_event({:call, from}, :pending_preconditions, _state, data) do
    {:keep_state, data, {:reply, from, pending_preconditions(data)}}
  end

  def handle_event({:call, from}, :pending_postconditions, :no_contracts_pending, data) do
    {:keep_state, data, {:reply, from, []}}
  end

  def handle_event({:call, from}, :pending_postconditions, _state, data) do
    {:keep_state, data, {:reply, from, pending_postconditions(data)}}
  end

  def handle_event({:call, from}, :invariants, _state, data) do
    {:keep_state, data, {:reply, from, invariants(data)}}
  end

  def handle_event({:call, from}, :pending_doc_attributes, :no_contracts_pending, data) do
    {:keep_state, data, {:reply, from, []}}
  end

  def handle_event({:call, from}, :pending_doc_attributes, _state, data) do
    {:keep_state, data, {:reply, from, pending_doc_attributes(data)}}
  end

  def handle_event({:call, from}, :annotated_functions, _state, data) do
    {:keep_state, data, {:reply, from, annotated_functions(data)}}
  end

  def handle_event({:call, from}, :functions_with_contracts, _state, data) do
    {:keep_state, data, {:reply, from, functions_with_contracts(data)}}
  end

  # NOTE: this clause is used only for testing purposes
  def handle_event(:cast, {:set_state, new_state}, _state, data) do
    {:next_state, new_state, data}
  end

  defp new_function_def?(function_def, data) do
    FunctionDefinition.mfa(function_def) != data.last_mfa
  end

  defp handle_new_function_def(function_def, :no_contracts_pending, data) do
    new_data = push_annotated_function(data, AnnotatedFunction.new(function_def))
    {:keep_state, new_data, :ok}
  end

  defp handle_new_function_def(function_def, :contracts_pending, data) do
    function_line = function_line(function_def)

    {applicable_pre, remaining_pre} = split_by_line(data.precondition_defs, function_line)
    {applicable_post, remaining_post} = split_by_line(data.postcondition_defs, function_line)

    {applicable_docs, remaining_docs} =
      split_doc_attrs_by_line(data.doc_attributes, function_line)

    annotated_function =
      function_def
      |> AnnotatedFunction.new()
      |> AnnotatedFunction.put_preconditions(Enum.reverse(applicable_pre))
      |> AnnotatedFunction.put_postconditions(Enum.reverse(applicable_post))
      |> AnnotatedFunction.put_doc_attributes(Enum.reverse(applicable_docs))

    new_data =
      data
      |> Map.put(:precondition_defs, remaining_pre)
      |> Map.put(:postcondition_defs, remaining_post)
      |> Map.put(:doc_attributes, remaining_docs)
      |> push_annotated_function(annotated_function)

    next_state = if has_pending?(new_data), do: :contracts_pending, else: :no_contracts_pending
    {{:next_state, next_state}, new_data, :ok}
  end

  defp handle_function_clause(function_def, _state, data) do
    function_line = function_line(function_def)

    contracts_between_clauses? =
      Enum.any?(data.precondition_defs, &assertion_below_line?(&1, function_line)) or
        Enum.any?(data.postcondition_defs, &assertion_below_line?(&1, function_line)) or
        Enum.any?(data.doc_attributes, &doc_attr_below_line?(&1, function_line))

    if contracts_between_clauses? do
      error =
        {:error,
         "cannot define contracts in between clauses of functions with the same name" <>
           " and arity - move all @pre and @post attributes before the first clause"}

      throw(error)
    end

    annotated_function =
      data
      |> last_annotated_function()
      |> AnnotatedFunction.add_clause(function_def)

    new_data = update_last_annotated_function(data, annotated_function)
    next_state = if has_pending?(new_data), do: :contracts_pending, else: :no_contracts_pending
    {{:next_state, next_state}, new_data, :ok}
  end

  defp function_line(%FunctionDefinition{env: env}), do: env.line

  # `items` is a list ordered newest-first (prepend on cast). Returns
  # `{applicable_newest_first, remaining_newest_first}` where `applicable` are items declared
  # on a source line strictly less than `line` and `remaining` are items at or after `line`.
  defp split_by_line(items, line) do
    Enum.split_with(items, &assertion_below_line?(&1, line))
  end

  defp split_doc_attrs_by_line(items, line) do
    Enum.split_with(items, &doc_attr_below_line?(&1, line))
  end

  defp assertion_below_line?(%Bond.Compiler.Assertion{} = a, line) do
    assertion_line(a) < line
  end

  defp assertion_line(%Bond.Compiler.Assertion{meta: meta, definition_env: env}) do
    Keyword.get(meta || [], :line) || env.line
  end

  defp doc_attr_below_line?({meta, _value}, line) when is_list(meta) do
    Keyword.get(meta, :line, 0) < line
  end

  defp has_pending?(data) do
    data.precondition_defs != [] or data.postcondition_defs != [] or data.doc_attributes != []
  end

  defp last_annotated_function(%{annotated_function_stack: stack} = _data) do
    Enum.at(stack, 0)
  end

  defp push_annotated_function(%{annotated_function_stack: stack} = data, annotated_function) do
    mfa = AnnotatedFunction.mfa(annotated_function)

    if MapSet.member?(data.mfa_set, mfa) do
      # This means that clauses of a multi-clause function are not grouped together.
      # While this is just a warning in Elixir, Bond explicitly disallows this because it
      # makes it ambiguous which function contracts should apply to.
      error =
        {:error,
         "clauses with the same name and arity (number of arguments) must be grouped together (#{inspect(mfa)})"}

      throw(error)
    end

    updated_stack = List.insert_at(stack, 0, annotated_function)
    updated_mfa_set = MapSet.put(data.mfa_set, mfa)

    %{data | annotated_function_stack: updated_stack, mfa_set: updated_mfa_set, last_mfa: mfa}
  end

  defp update_last_annotated_function(
         %{annotated_function_stack: stack} = data,
         annotated_function
       ) do
    [last_annotated_function | stack] = stack

    if AnnotatedFunction.mfa(annotated_function) !=
         AnnotatedFunction.mfa(last_annotated_function) do
      throw({:error, "Bond internal error"})
    end

    updated_stack = List.insert_at(stack, 0, annotated_function)
    %{data | annotated_function_stack: updated_stack}
  end

  defp annotated_functions(%{annotated_function_stack: annotated_function_stack}) do
    Enum.reverse(annotated_function_stack)
  end

  defp functions_with_contracts(%{functions_with_contracts: functions_with_contracts}) do
    Enum.reverse(functions_with_contracts)
  end

  defp pending_preconditions(data) do
    Enum.reverse(data.precondition_defs)
  end

  defp pending_postconditions(data) do
    Enum.reverse(data.postcondition_defs)
  end

  defp invariants(data) do
    Enum.reverse(data.invariant_defs)
  end

  defp pending_doc_attributes(data) do
    Enum.reverse(data.doc_attributes)
  end

  defp clear_pending_contracts(data) do
    %{data | precondition_defs: [], postcondition_defs: [], doc_attributes: []}
  end

  defp clear_pending_doc_attributes(data) do
    %{data | doc_attributes: []}
  end
end
