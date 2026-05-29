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

  alias Bond.Compiler.FunctionDefinition
  # `require` (not `alias`) so Mix creates a strong compile-time dep on the Server module
  # and schedules server.ex before this file. Without this, the parallel compiler on
  # Elixir 1.19+ can race: test-support files call `use Bond` (which starts the gen_statem)
  # before CompileStateFSM.Server.beam has been written to disk.
  require Bond.Compiler.CompileStateFSM.Server, as: FSMServer

  @type server_ref :: :gen_statem.server_ref()
  @type state :: :no_contracts_pending | :contracts_pending | :error | :done
  @type function_def :: Bond.Compiler.FunctionDefinition.t()
  @type precondition_def :: Bond.Compiler.Assertion.t()
  @type postcondition_def :: Bond.Compiler.Assertion.t()
  @type invariant_def :: Bond.Compiler.Assertion.t()

  @doc """
  Returns the local name registration of the FSM process for the given module.
  """
  def server_ref(module), do: Module.concat(__MODULE__, module)

  @doc """
  Starts a new FSM process for the given module.
  """
  @spec start_link(module()) :: {:ok, pid()} | {:error, reason :: term()}
  def start_link(module) when is_atom(module) do
    # Deterministically defeat the parallel-compile race (Elixir 1.19+): this runs at the
    # *user* module's compile time (via `Bond.Compiler.init/1` in the `use Bond` expansion),
    # and the gen_statem callback module plus the structs its callbacks build must already be
    # compiled to disk. The `require` chain from bond.ex is meant to schedule them first, but
    # that ordering is not reliably honoured under the parallel compiler — a change to
    # server.ex alone can flip a previously-working race, surfacing as
    # `CompileStateFSM.Server.init/1 is undefined` / "module ... is not available". Blocking on
    # `Code.ensure_compiled!/1` waits for each module's compilation to finish, removing the
    # race regardless of scheduling. (Safe from deadlock: none of these modules has a
    # compile-time dependency back on this one or on the user module being compiled.)
    Enum.each(
      [
        Bond.Compiler.CompileStateFSM.Server,
        Bond.Compiler.AnnotatedFunction,
        Bond.Compiler.AnnotatedFunction.Clause,
        Bond.Compiler.FunctionDefinition
      ],
      &Code.ensure_compiled!/1
    )

    case :gen_statem.start_link({:local, server_ref(module)}, FSMServer, module, []) do
      {:ok, _pid} = ok ->
        ok

      {:error, {:already_started, stale_pid}} ->
        # A previous compile of this module left its FSM registered under the
        # per-module name. Under one-shot `mix compile` this never happens (the BEAM
        # exits before it matters), but in a long-lived session — ElixirLS recompiling
        # on every edit, or IEx — an aborted compile (e.g. a transient syntax error
        # while typing) can return before `__after_compile__` stops the FSM. The leftover
        # holds stale state from that aborted compile, so discard it and start fresh
        # rather than reusing it. The name is unique per module, so an `already_started`
        # is always such a leftover, never a legitimate concurrent owner.
        # `stop/1` can raise `:noproc` if the leftover happens to die between
        # `start_link` reporting it and this call (its linking worker exiting
        # abnormally); either way the name is then free, so ignore that exit.
        try do
          stop(stale_pid)
        catch
          :exit, _ -> :ok
        end

        :gen_statem.start_link({:local, server_ref(module)}, FSMServer, module, [])
    end
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
  Sends an `invariant_def` event to the FSM.

  Unlike preconditions/postconditions, invariants are module-scoped: they accumulate over the
  whole module and apply to every public function regardless of declaration order. The state
  machine therefore does not transition into `:contracts_pending` on this event, and
  invariants are not flushed by function definitions.
  """
  @spec invariant_def(server_ref(), invariant_def()) :: :ok
  def invariant_def(fsm, invariant_def) do
    :gen_statem.cast(fsm, {:invariant_def, invariant_def})
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
  Returns the module-scoped invariants, in declaration order.

  Invariants are not per-function. The list returned here applies to every public function in
  the module that qualifies for invariant checking (see `Bond.Compiler.AnnotatedFunction`).
  """
  @spec invariants(server_ref) :: list(invariant_def)
  def invariants(fsm) do
    :gen_statem.call(fsm, :invariants)
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
end
