defmodule Bond.CompileStateFSM do
  @moduledoc internal: true
  @moduledoc """
  Finite State Machine (FSM) holding compile-time state for modules that use `Bond`.

  The states recognized by this FSM are:

    * `:no_contracts_pending` - initial state before any function or contract definitions have been
      encountered
    * `:contracts_pending` - one or more `@pre` or `@post` has been encountered and will be
      applied to the next function definition
    * `:contracts_apply` - a function definition has been encountered in the `:contracts_pending`
      state and the function should be wrapped with the pending contracts
  """

  @type server_ref :: pid | atom
  @type state :: :no_contracts_pending | :contracts_pending | :contracts_apply
  @type function_def :: {name :: atom, list, parameters :: list | nil}
  @type precondition_def :: Bond.Assertion.t()
  @type postcondition_def :: Bond.Assertion.t()
  @type doc_attribute :: {:doc, meta :: Keyword.t(), value :: doc_attribute_value()}
  @type doc_attribute_value :: String.t() | Keyword.t()

  @doc """
  Starts a new FSM process for the given module.
  """
  @spec start_link(module) :: {:ok, pid} | {:error, reason :: term}
  def start_link(module) when is_atom(module),
    do: :gen_statem.start_link(__MODULE__.Server, module, [])

  @doc "Stop the FSM process."
  @spec stop(server_ref) :: :ok
  def stop(fsm), do: :gen_statem.stop(fsm)

  @doc """
  Returns the current state of the FSM as an atom.
  """
  @spec current_state(server_ref) :: state
  def current_state(fsm), do: :gen_statem.call(fsm, :get_state)

  @doc """
  Sends a `function_def` event to the FSM.

  Raises a `CompileError` if the FSM is in an error state.
  """
  @spec function_def(server_ref, function_def) :: :ok | no_return
  def function_def(fsm, definition) do
    case :gen_statem.call(fsm, {:function_def, definition}) do
      :ok -> :ok
      {:error, reason} -> raise CompileError, description: reason
    end
  end

  @doc """
  Sends a `precondition_def` event to the FSM.
  """
  @spec precondition_def(server_ref, precondition_def) :: :ok
  def precondition_def(fsm, definition) do
    :gen_statem.cast(fsm, {:precondition_def, definition})
  end

  @doc """
  Sends a `postcondition_def` event to the FSM.
  """
  @spec postcondition_def(server_ref, postcondition_def) :: :ok
  def postcondition_def(fsm, definition) do
    :gen_statem.cast(fsm, {:postcondition_def, definition})
  end

  @doc """
  Sends a `doc_attribute` devent to the FSM.
  """
  def doc_attribute(fsm, doc_value) do
    :gen_statem.cast(fsm, {:doc_attribute, doc_value})
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
  @spec pending_doc_attributes(server_ref) :: list(doc_attribute())
  def pending_doc_attributes(fsm) do
    :gen_statem.call(fsm, :pending_doc_attributes)
  end

  defmodule Server do
    @moduledoc false
    @behaviour :gen_statem

    defstruct module: nil,
              last_function_def: nil,
              precondition_defs: [],
              postcondition_defs: [],
              doc_attributes: []

    @impl :gen_statem
    def callback_mode, do: :handle_event_function

    @impl :gen_statem
    def init(module) when is_atom(module),
      do: {:ok, :no_contracts_pending, %__MODULE__{module: module}}

    @impl :gen_statem
    def handle_event({:call, from}, :get_state, state, data) do
      {:keep_state, data, [{:reply, from, state}]}
    end

    def handle_event({:call, from}, {:function_def, definition}, :no_contracts_pending, data) do
      {:keep_state, record_function_def(data, definition), {:reply, from, :ok}}
    end

    def handle_event({:call, from}, {:function_def, definition}, :contracts_pending, data) do
      if function_id(definition) == data.last_function_def do
        error =
          {:error,
           "cannot define contracts in between clauses of functions with the same name" <>
             " and arity (number of arguments)"}

        {:next_state, :no_contracts_pending, clear_pending_contracts(data), {:reply, from, error}}
      else
        {:next_state, :contracts_apply, record_function_def(data, definition),
         {:reply, from, :ok}}
      end
    end

    def handle_event({:call, from}, {:function_def, definition}, :contracts_apply, data) do
      if function_id(definition) == data.last_function_def do
        {:keep_state, data, {:reply, from, :ok}}
      else
        new_data =
          data
          |> record_function_def(definition)
          |> clear_pending_contracts()

        {:next_state, :no_contracts_pending, new_data, {:reply, from, :ok}}
      end
    end

    def handle_event(:cast, {:precondition_def, definition}, state, data)
        when state in [:no_contracts_pending, :contracts_pending] do
      new_data = update_in(data.precondition_defs, &[definition | &1])
      {:next_state, :contracts_pending, new_data}
    end

    def handle_event(:cast, {:precondition_def, definition}, :contracts_apply, data) do
      data = clear_pending_contracts(data)
      new_data = put_in(data.precondition_defs, [definition])
      {:next_state, :contracts_pending, new_data}
    end

    def handle_event(:cast, {:postcondition_def, definition}, state, data)
        when state in [:no_contracts_pending, :contracts_pending] do
      new_data = update_in(data.postcondition_defs, &[definition | &1])
      {:next_state, :contracts_pending, new_data}
    end

    def handle_event(:cast, {:postcondition_def, definition}, :contracts_apply, data) do
      data = clear_pending_contracts(data)
      new_data = put_in(data.postcondition_defs, [definition])
      {:next_state, :contracts_pending, new_data}
    end

    def handle_event(:cast, {:doc_attribute, doc_value}, state, data)
        when state in [:no_contracts_pending, :contracts_pending] do
      new_data = update_in(data.doc_attributes, &[doc_value | &1])
      {:next_state, :contracts_pending, new_data}
    end

    def handle_event(:cast, {:doc_attribute, doc_value}, :contracts_apply, data) do
      data = clear_pending_contracts(data)
      new_data = put_in(data.doc_attributes, [doc_value])
      {:next_state, :contracts_pending, new_data}
    end

    def handle_event({:call, from}, :pending_preconditions, :no_contracts_pending, data) do
      {:keep_state, data, {:reply, from, []}}
    end

    def handle_event({:call, from}, :pending_preconditions, _state, data) do
      {:keep_state, data, {:reply, from, Enum.reverse(data.precondition_defs)}}
    end

    def handle_event({:call, from}, :pending_postconditions, :no_contracts_pending, data) do
      {:keep_state, data, {:reply, from, []}}
    end

    def handle_event({:call, from}, :pending_postconditions, _state, data) do
      {:keep_state, data, {:reply, from, Enum.reverse(data.postcondition_defs)}}
    end

    def handle_event({:call, from}, :pending_doc_attributes, :no_contracts_pending, data) do
      {:keep_state, data, {:reply, from, []}}
    end

    def handle_event({:call, from}, :pending_doc_attributes, _state, data) do
      {:keep_state, data, {:reply, from, Enum.reverse(data.doc_attributes)}}
    end

    # NOTE: this clause is used only for testing purposes
    def handle_event(:cast, {:set_state, new_state}, _state, data) do
      {:next_state, new_state, data}
    end

    defp function_id({name, _, nil}), do: {name, 0}
    defp function_id({name, _, params}) when is_list(params), do: {name, length(params)}

    defp record_function_def(data, definition) do
      %{data | last_function_def: function_id(definition)}
    end

    defp clear_pending_contracts(data) do
      %{data | precondition_defs: [], postcondition_defs: [], doc_attributes: []}
    end
  end
end
