defmodule Bond do
  # Pull in the moduledocs from the demarcated section of the README file
  @readme Path.expand("./README.md")
  @external_resource @readme
  @moduledoc @readme
             |> File.read!()
             |> String.split("<!-- README START -->")
             |> Enum.at(1)
             |> String.split("<!-- README END -->")
             |> List.first()

  # `require` (not `alias`) so Mix creates strong compile-time deps on both
  # Bond.Compiler and Bond.Compiler.AnnotatedFunction, and schedules both
  # before this file. Every user module has a compile dep on bond.ex via
  # `use Bond`, so this transitively ensures:
  #
  #   (a) Bond.Compiler.AnnotatedFunction is compiled before any user
  #       module's @on_definition callbacks fire (the original 0.17.4 race
  #       fix, see the bond-compile-order memory note).
  #   (b) The full chain Bond.Compiler → CompileStateFSM → Server is on
  #       disk before this file's __using__ macro body calls
  #       `Bond.Compiler.init/1` (which starts the gen_statem).
  #
  # (b) is needed because the call to Bond.Compiler.init/1 from the macro
  # body would otherwise be just a fully-qualified reference — sometimes
  # tracked as a compile dep by Mix's parallel scheduler, sometimes not.
  # Under cache-warm CI conditions, a doc-only change to server.ex was
  # enough to flip a previously-working race and break compilation of
  # `use Bond` modules — see the gotcha note for the symptom + diagnosis.
  require Bond.Compiler
  require Bond.Compiler.AnnotatedFunction

  @typedoc false
  @type assertion_kind :: :precondition | :postcondition | :check | :invariant

  @typedoc """
  Type to represent a label for an assertion, which must be a compile-time atom or string.
  """
  @type assertion_label :: String.t() | atom()

  @typedoc """
  Type to represent a compile-time quoted assertion expression, which must be a valid Elixir
  expression that, when unquoted, evaluates to a `t:boolean/0` or `t:as_boolean/1` value.
  """
  @type assertion_expression :: {atom(), Macro.metadata(), list()}

  @doc """
  `use Bond` enables `@pre`, `@post`, and `check/1` annotations in the using module.

  ## Options

  Each option is one of `true`, `false`, or `:purge`. See the "Conditional compilation"
  section in the moduledoc for what each value means. Options passed to `use Bond` override
  both the global `:bond` config and any `:overrides` entry that matches this module.

    * `:preconditions` — mode for this module's `@pre` annotations.
    * `:postconditions` — mode for this module's `@post` annotations.
    * `:checks` — mode for this module's `check/1` calls.
    * `:invariants` — mode for this module's `@invariant` annotations.

  Example: a hot-path module that wants contracts purged from its compiled output regardless
  of the global config.

      defmodule MyApp.HotPath do
        use Bond, preconditions: :purge, postconditions: :purge
      end
  """
  defmacro __using__(opts) when is_list(opts) do
    Bond.Compiler.init(__CALLER__.module)

    quote do
      # Read the `:bond` application config in the *user's* module body so
      # `Application.compile_env/3` works (it cannot be called inside a macro/function body,
      # only in a module body) and so the compile-env dependency is correctly tracked for
      # recompilation. `Bond.Compiler.resolve_config/3` merges global config, `:overrides`,
      # and the `use Bond` opts. `Bond.Compiler.__before_compile__/1` reads the final
      # `@__bond_contract_config__` attribute when emitting contract overrides.
      @__bond_contract_config__ Bond.Compiler.resolve_config(
                                  __MODULE__,
                                  unquote(opts),
                                  preconditions:
                                    Application.compile_env(:bond, :preconditions, true),
                                  postconditions:
                                    Application.compile_env(:bond, :postconditions, true),
                                  checks: Application.compile_env(:bond, :checks, true),
                                  invariants: Application.compile_env(:bond, :invariants, true),
                                  overrides: Application.compile_env(:bond, :overrides, []),
                                  warn_skipped_invariants:
                                    Application.compile_env(
                                      :bond,
                                      :warn_skipped_invariants,
                                      true
                                    )
                                )

      import Kernel, except: [@: 1]
      import Bond

      @on_definition Bond.Compiler
      @before_compile Bond.Compiler
      @after_compile Bond.Compiler
    end
  end

  @doc """
  Override `Kernel.@/1` to support `@pre` and `@post` annotations.

  See the `Bond` module docs for the syntax of `@pre` and `@post` annotations.
  """
  defmacro @pre_or_post

  # This clause handles either "bare" @pre or @post assertions that do not have a label
  # attached to them, or keyword lists where the keys are labels and the values are the
  # assertions.
  defmacro @{pre_or_post, meta, [expression]} when pre_or_post in [:pre, :post] do
    if Keyword.keyword?(expression) do
      for {label, expression} <- expression do
        Bond.Compiler.register_assertion(pre_or_post, expression, label, __CALLER__, meta)
      end
    else
      Bond.Compiler.register_assertion(pre_or_post, expression, nil, __CALLER__, meta)
    end

    :ok
  end

  # This clause handles @pre or @post assertions that have a label preceding them.
  defmacro @{pre_or_post, meta, [label, {_, _, _} = expression]}
           when (pre_or_post in [:pre, :post] and is_atom(label)) or is_binary(label) do
    Bond.Compiler.register_assertion(pre_or_post, expression, label, __CALLER__, meta)
    :ok
  end

  # This clause handles @pre or @post assertions that have a label following them.
  defmacro @{pre_or_post, meta, [{_, _, _} = expression, label]}
           when (pre_or_post in [:pre, :post] and is_atom(label)) or is_binary(label) do
    Bond.Compiler.register_assertion(pre_or_post, expression, label, __CALLER__, meta)
    :ok
  end

  # Catch-all for `@pre`/`@post` with 2+ args that don't match the label-first,
  # label-last, or single-arg patterns above. The common trip is mixing a bare
  # assertion with a labelled one (`@pre is_binary(x), positive: x > 0`) —
  # Elixir parses that as two args, neither valid for the existing clauses, so
  # it would otherwise fall through to Kernel's `@/1` and die with an unhelpful
  # arity error. Raise a clearer diagnostic here.
  defmacro @{pre_or_post, _meta, [_, _ | _] = args}
           when pre_or_post in [:pre, :post] do
    raise CompileError,
      file: __CALLER__.file,
      line: __CALLER__.line,
      description:
        "@#{pre_or_post} accepts a single argument — either a bare assertion expression " <>
          "or a keyword list of label: assertion pairs. Got #{length(args)} arguments " <>
          "(likely a bare assertion mixed with labelled assertions, e.g. " <>
          "`@#{pre_or_post} is_binary(x), positive: x > 0`). Either label every " <>
          "assertion (`@#{pre_or_post} binary: is_binary(x), positive: x > 0`) or use " <>
          "a separate @#{pre_or_post} line per bare assertion."
  end

  # @invariant <expression-or-keyword-list>
  #
  # Invariant expressions reference the implicit `subject` binding, which Bond rebinds at
  # every check site to whichever struct parameter the function head exposes (detected
  # via `Bond.Compiler.Invariants.detect_struct_params/2`).
  defmacro @{:invariant, meta, [expression_or_kw_list]} do
    if Keyword.keyword?(expression_or_kw_list) do
      for {label, expression} <- expression_or_kw_list do
        Bond.Compiler.register_invariant(expression, label, __CALLER__, meta)
      end
    else
      Bond.Compiler.register_invariant(expression_or_kw_list, nil, __CALLER__, meta)
    end

    :ok
  end

  # @invariant <name>, <expression-or-keyword-list>
  #
  # Removed in Bond 0.16.0. The legacy 2-arg shape now raises a CompileError pointing at
  # the migration. Drop the binding name; invariant expressions reference the implicit
  # `subject` binding.
  defmacro @{:invariant, _meta, [{name, _, ctx}, _expression_or_kw_list]}
           when is_atom(name) and is_atom(ctx) do
    raise CompileError,
      file: __CALLER__.file,
      line: __CALLER__.line,
      description:
        "@invariant <name>, <expr> was removed in Bond 0.16.0. Drop the binding name; " <>
          "invariant expressions reference the implicit `subject` binding. Example: " <>
          "`@invariant subject.field > 0` instead of `@invariant stack, stack.field > 0`."
  end

  # Catch-all for `@invariant` with 2+ args that don't match the legacy
  # `@invariant <atom>, <expr>` shape above. Same trip as `@pre`/`@post`:
  # mixing a bare assertion with a labelled one (`@invariant subject.x >= 0,
  # positive: subject.y > 0`) parses as two args, neither valid, and would
  # otherwise fall through to Kernel's `@/1` with an arity error.
  defmacro @{:invariant, _meta, [_, _ | _] = args} do
    raise CompileError,
      file: __CALLER__.file,
      line: __CALLER__.line,
      description:
        "@invariant accepts a single argument — either a bare expression or a " <>
          "keyword list of label: expression pairs. Got #{length(args)} arguments " <>
          "(likely a bare expression mixed with labelled ones, e.g. " <>
          "`@invariant subject.x >= 0, positive: subject.y > 0`). Either label every " <>
          "expression (`@invariant non_negative: subject.x >= 0, positive: subject.y > 0`) " <>
          "or use a separate @invariant line per bare expression."
  end

  defmacro @{:doc, meta, [value]} do
    Bond.Compiler.register_doc(__CALLER__, meta, value)
    :ok
  end

  defmacro @attr do
    # Forward any other module attributes that are not `@pre` or `@post` to `Kernel.@/1`
    quote do
      Kernel.@(unquote(attr))
    end
  end

  @doc """
  Check an assertion or a keyword list of assertions for validity.

  Returns the result(s) of the assertion(s) if satisfied, or raises a `Bond.CheckError` exception
  if any assertions are not satisfied.

  ## Examples

      iex> check 1 == 1.0
      true
      iex> check tautology: 1 == 1
      [true]
      iex> check "1 is 1": 1 == 1, "2 is 2": 2 == 2
      [true, true]

  > #### Conditional compilation {: .info}
  >
  > `check` honours the `:bond, :checks` application config:
  >
  > - `:purge` — `check` calls in modules that `use Bond` expand to `:ok` at compile time and
  >   the wrapped expression is **not evaluated** at all. Don't rely on side effects in checks.
  > - `true` (default) — `check` calls expand to a runtime-guarded evaluation; the guard reads
  >   `Application.get_env(:bond, :checks, true)` on every call and evaluates unless the value
  >   is `false`.
  > - `false` — same shape as `true`, but the runtime default flips to `false` (off unless
  >   `Application.put_env/3` is called to turn it on).
  """
  @spec check(assertion_expression()) :: as_boolean(any())
  @spec check(Keyword.t(assertion_expression())) :: list(as_boolean(any()))
  defmacro check(assertion_or_list_of_assertions)

  defmacro check(keyword_list) when is_list(keyword_list) do
    build_check(__CALLER__.module, fn mode ->
      for {label, {_, meta, _} = expression} <- keyword_list do
        Bond.Compiler.check_assertion(expression, label, __CALLER__, meta, mode)
      end
    end)
  end

  defmacro check({_, meta, _} = expression) do
    build_check(__CALLER__.module, fn mode ->
      Bond.Compiler.check_assertion(expression, nil, __CALLER__, meta, mode)
    end)
  end

  @doc false
  # `check/2` was removed in Bond 0.16.0. The two string-label forms (`check "lbl", expr`
  # and `check expr, "lbl"`) and the atom-label form (`check :lbl, expr`) collapse to the
  # keyword-list form: `check lbl: expr`. This shim raises a clear migration error for any
  # arity-2 call at the use site.
  defmacro check(_label_or_expression, _expression_or_label) do
    raise CompileError,
      file: __CALLER__.file,
      line: __CALLER__.line,
      description:
        "check/2 was removed in Bond 0.16.0. Use `check expr` or `check label: expr` " <>
          "instead. The string-label forms `check \"label\", expr` and " <>
          "`check expr, \"label\"` are no longer supported."
  end

  # Build the AST for a `check` call honouring the per-module `:checks` config:
  #
  #   * `:purge` — expand to `:ok` at compile time; `build_inline_ast` is never called and
  #     the wrapped expression is not evaluated at runtime.
  #   * `true` / `false` — call `build_inline_ast` with the compile-time-resolved mode to
  #     produce the call(s) to `Bond.Runtime.Eval.evaluate_check/2`. The runtime guard
  #     (`Application.get_env/3` defaulting to the compile-time mode) lives inside `Eval`.
  defp build_check(module, build_inline_ast) do
    case checks_mode(module) do
      :purge -> :ok
      mode when mode in [true, false] -> build_inline_ast.(mode)
    end
  end

  # Read the per-module `:checks` config previously stashed by `__using__`. Modules that did
  # not `use Bond` have no attribute set; in that case default to `true` (a defensive choice —
  # such a `check` call would otherwise be a no-op for surprising reasons).
  defp checks_mode(module) do
    case Module.get_attribute(module, :__bond_contract_config__) do
      %{checks: mode} when mode in [true, false, :purge] -> mode
      _ -> true
    end
  end
end
