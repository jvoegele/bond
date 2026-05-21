defmodule Bond.Compiler.CompileStateFSM do
  @moduledoc internal: true
  @moduledoc """
  Finite State Machine (FSM) holding compile-time state for modules that use `Bond`.

  The states recognized by this FSM are:

    * `:no_contracts_pending` - initial state before any function or contract definitions have been
      encountered
    * `:contracts_pending` - one or more `@pre` or `@post` has been encountered and will be
      applied to the next function definition
    * `:error` - an error was encountered that invalidates the FSM, which should no longer be used
    * `:done` - terminal state that indicates that the module has been fully defined (although
      not yet compiled)
  """

  alias Bond.Compiler.AnnotatedFunction
  alias Bond.Compiler.FunctionDefinition

  @type server_ref :: :gen_statem.server_ref()
  @type state :: :no_contracts_pending | :contracts_pending | :error | :done
  @type function_def :: Bond.Compiler.FunctionDefinition.t()
  @type precondition_def :: Bond.Compiler.Assertion.t()
  @type postcondition_def :: Bond.Compiler.Assertion.t()

  @doc """
  Returns the local name registration of the FSM process for the given module.
  """
  def server_ref(module), do: Module.concat(__MODULE__, module)

  @doc """
  Starts a new FSM process for the given module.
  """
  @spec start_link(module()) :: {:ok, pid()} | {:error, reason :: term()}
  def start_link(module) when is_atom(module) do
    :gen_statem.start_link({:local, server_ref(module)}, __MODULE__.Server, module, [])
  end

  @doc "Stop the FSM process."
  @spec stop(server_ref()) :: :ok
  def stop(fsm), do: :gen_statem.stop(fsm)

  @doc """
  Returns the current state of the FSM as an atom.
  """
  @spec current_state(server_ref()) :: state
  def current_state(fsm), do: :gen_statem.call(fsm, :get_state)

  @doc """
  Sends a `function_def` event to the FSM.

  Raises a `CompileError` if the FSM is in an error state.
  """
  @spec function_def(server_ref(), function_def()) :: :ok | no_return()
  def function_def(fsm, %FunctionDefinition{} = function_def) do
    case :gen_statem.call(fsm, {:function_def, function_def}) do
      :ok -> :ok
      {:error, reason} -> raise CompileError, description: reason
    end
  end

  @doc """
  Sends a `precondition_def` event to the FSM.
  """
  @spec precondition_def(server_ref(), precondition_def()) :: :ok
  def precondition_def(fsm, precondition_def) do
    :gen_statem.cast(fsm, {:precondition_def, precondition_def})
  end

  @doc """
  Sends a `postcondition_def` event to the FSM.
  """
  @spec postcondition_def(server_ref(), postcondition_def()) :: :ok
  def postcondition_def(fsm, postcondition_def) do
    :gen_statem.cast(fsm, {:postcondition_def, postcondition_def})
  end

  @doc """
  Sends a `doc_attribute` event to the FSM.
  """
  def doc_attribute(fsm, doc_value) do
    :gen_statem.cast(fsm, {:doc_attribute, doc_value})
  end

  @doc """
  Sends a `doc_attributes_applied` event to the FSM.
  """
  def doc_attributes_applied(fsm) do
    :gen_statem.cast(fsm, :doc_attributes_applied)
  end

  @doc """
  Sends a `module_defined` event to the FSM.

  Raises a `CompileError` if the FSM is in an error state.
  """
  def module_defined(fsm) do
    case :gen_statem.call(fsm, :module_defined) do
      :ok -> :ok
      {:error, reason} -> raise CompileError, description: reason
    end
  end

  @doc """
  Returns a list containing all pending precondition definitions.
  """
  @spec pending_preconditions(server_ref) :: list(precondition_def)
  def pending_preconditions(fsm) do
    :gen_statem.call(fsm, :pending_preconditions)
  end

  @doc """
  Returns a list containing all pending postcondition definitions.
  """
  @spec pending_postconditions(server_ref) :: list(postcondition_def)
  def pending_postconditions(fsm) do
    :gen_statem.call(fsm, :pending_postconditions)
  end

  @doc """
  Returns a list containing all pending @doc attributes.
  """
  @spec pending_doc_attributes(server_ref) ::
          list(Bond.Compiler.FunctionDefinition.doc_attribute())
  def pending_doc_attributes(fsm) do
    :gen_statem.call(fsm, :pending_doc_attributes)
  end

  @doc """
  Returns a list of all annotated function definitions that have been tracked by the FSM.
  """
  def annotated_functions(fsm) do
    :gen_statem.call(fsm, :annotated_functions)
  end

  @doc """
  Returns a list of all function definitions that have associated contracts.
  """
  def functions_with_contracts(fsm) do
    :gen_statem.call(fsm, :functions_with_contracts)
  end

  defmodule Server do
    @moduledoc false
    @behaviour :gen_statem

    alias Bond.Compiler.AnnotatedFunction
    alias Bond.Compiler.FunctionDefinition

    defstruct module: nil,
              last_mfa: nil,
              function_def_stack: [],
              annotated_function_stack: [],
              mfa_set: MapSet.new(),
              precondition_defs: [],
              postcondition_defs: [],
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
      {applicable_docs, remaining_docs} = split_doc_attrs_by_line(data.doc_attributes, function_line)

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
end
