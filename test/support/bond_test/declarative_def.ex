defmodule BondTest.DeclarativeDef do
  @moduledoc """
  A miniature of `Phoenix.Component.Declarative`, for regression tests around #134.

  Bond cannot depend on `phoenix_live_view` to test composing with it, and the part that matters
  is small and stable: `Phoenix.Component` imports its own `def`/`defp`, rewrites **arity-1 heads
  only** so the single parameter is wrapped in a macro call, and that macro asserts it is
  expanding inside an arity-1 function:

      defmacro __pattern__!(kind, arg) do
        {name, 1} = __CALLER__.function
        ...

  The bug that shape exposed was Bond replaying a captured parameter AST — which by then held a
  foreign macro call — inside generated helpers of a *different* arity, where the assertion blew
  up on an internal tuple naming neither Bond nor arity.

  `expansions/0` records every `{name, arity}` this macro expanded inside, so a test can assert
  that generated code carries no copy of it, and that the macro ran exactly once per user
  function rather than once per definition Bond emits (re-running it would duplicate a real
  library's registration side effects).
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Kernel, except: [def: 2, defp: 2]
      import BondTest.DeclarativeDef, only: [def: 2, defp: 2]
    end
  end

  @doc false
  defmacro def(expr, body) do
    quote do
      Kernel.def(unquote(annotate_def(:def, expr)), unquote(body))
    end
  end

  @doc false
  defmacro defp(expr, body) do
    quote do
      Kernel.defp(unquote(annotate_def(:defp, expr)), unquote(body))
    end
  end

  @doc """
  Every `{name, arity}` that `__pattern__!/2` expanded inside, most recent first.

  Collected in the process dictionary because expansion happens at compile time, in the process
  compiling the module.
  """
  @spec expansions() :: [{atom(), arity()}]
  def expansions, do: Process.get(__MODULE__, [])

  @doc false
  defmacro __pattern__!(_kind, arg) do
    # The assertion Phoenix makes. A copy replayed inside a generated arity-2 helper raises here.
    {_name, 1} = __CALLER__.function
    Process.put(__MODULE__, [__CALLER__.function | Process.get(__MODULE__, [])])
    arg
  end

  @doc """
  Documents the *next* definition, the way `Phoenix.Component`'s `attr/3` ends up documenting a
  component from its declarations.

  The point for #136 is that this doc is set by a library rather than written by the user, so
  Bond has no record of it at `@on_definition` and cannot tell it is about to collide.
  """
  defmacro documented_by_the_library(text) do
    quote do
      @doc unquote(text)
    end
  end

  defp annotate_def(kind, expr) do
    case expr do
      {:when, meta, [left, right]} -> {:when, meta, [annotate_call(kind, left), right]}
      left -> annotate_call(kind, left)
    end
  end

  # Arity-1 heads only, exactly as Phoenix does.
  defp annotate_call(kind, {name, meta, [arg]}), do: {name, meta, [annotate_arg(kind, arg)]}
  defp annotate_call(_kind, left), do: left

  defp annotate_arg(kind, {:=, meta, [{name, _, ctx} = var, arg]})
       when is_atom(name) and is_atom(ctx) do
    {:=, meta,
     [var, quote(do: BondTest.DeclarativeDef.__pattern__!(unquote(kind), unquote(arg)))]}
  end

  defp annotate_arg(kind, {name, meta, ctx} = var) when is_atom(name) and is_atom(ctx) do
    {:=, meta, [quote(do: BondTest.DeclarativeDef.__pattern__!(unquote(kind), _)), var]}
  end

  defp annotate_arg(kind, arg) do
    quote(do: BondTest.DeclarativeDef.__pattern__!(unquote(kind), unquote(arg)))
  end
end
