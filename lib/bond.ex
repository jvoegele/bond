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
  @type assertion_kind ::
          :precondition
          | :postcondition
          | :check
          | :invariant
          | :state_invariant
          | :transition_invariant

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

  When the module also inherits contracts (`use Bond, behaviours: […]`), `@pre_weaken` and
  `@post_strengthen` are additionally available to *refine* an inherited contract — weakening a
  precondition and strengthening a postcondition respectively, per Eiffel's behavioural-subtyping
  rules. See `Bond.Behaviour`.

  ## Options

  Each of the following options is one of `true`, `false`, or `:purge`. See the "Conditional
  compilation" section in the moduledoc for what each value means. Options passed to
  `use Bond` override both the global `:bond` config and any `:overrides` entry that matches
  this module.

    * `:preconditions` — mode for this module's `@pre` annotations.
    * `:postconditions` — mode for this module's `@post` annotations.
    * `:checks` — mode for this module's `check/1` calls.
    * `:invariants` — mode for this module's `@invariant` annotations.

  Example: a hot-path module that wants contracts purged from its compiled output regardless
  of the global config.

      defmodule MyApp.HotPath do
        use Bond, preconditions: :purge, postconditions: :purge
      end

  ### `:at_annotations`

  Controls Bond's `@`-prefixed annotation syntax — `@pre`, `@post`, and `@invariant`. By
  default (`true`) Bond overrides `Kernel.@/1` in the using module so those forms are
  recognised. Overriding `@` is lexically scoped to this module, so it is invisible to the
  rest of your project — but it cannot coexist *within a single module* with another library
  that also overrides `@` (for example Norm's `@contract`).

  Pass `at_annotations: false` to leave `Kernel.@/1` untouched in this module. Bond's compiler
  hooks are still installed, but the `@pre`/`@post`/`@invariant` forms are **not** available;
  instead, write contracts as fully-qualified calls — `Bond.pre/1`, `Bond.post/1`, and
  `Bond.invariant/1`. `check/1` remains available unqualified.

      defmodule MyApp.Validated do
        use Norm
        use Bond, at_annotations: false

        @contract add(integer(), integer()) :: integer()
        Bond.pre x >= 0 and y >= 0
        Bond.post result >= 0
        def add(x, y), do: x + y
      end

  > #### Bare macros are always fully-qualified {: .info}
  >
  > The `pre`/`post`/`invariant` macros are never imported, even with the default
  > `at_annotations: true`. This keeps them from colliding with common function names (notably
  > `post`) in modules that only ever use the `@` forms. They are reachable only as
  > `Bond.pre`, `Bond.post`, and `Bond.invariant`.
  """
  defmacro __using__(opts) when is_list(opts) do
    Bond.Compiler.init(__CALLER__.module)

    {at_annotations?, opts_without_at} = Keyword.pop(opts, :at_annotations, true)

    # Resolve the `:behaviours` option's module references in the caller's context (they arrive
    # as unresolved `__aliases__` AST) and register their inherited contracts with this module's
    # FSM. The call to each behaviour's `__bond_contracts__/0` establishes the compile-time
    # dependency that forces the behaviour to be compiled first.
    {behaviours_opt, use_opts} = Keyword.pop(opts_without_at, :behaviours, [])

    behaviour_mods =
      behaviours_opt
      |> List.wrap()
      |> Enum.map(&Macro.expand(&1, __CALLER__))

    Bond.Compiler.register_behaviours(__CALLER__.module, behaviour_mods, __CALLER__)

    behaviours_ast =
      for behaviour <- behaviour_mods do
        quote do
          @behaviour unquote(behaviour)
        end
      end

    config_ast =
      quote do
        # Read the `:bond` application config in the *user's* module body so
        # `Application.compile_env/3` works (it cannot be called inside a macro/function body,
        # only in a module body) and so the compile-env dependency is correctly tracked for
        # recompilation. `Bond.Compiler.resolve_config/3` merges global config, `:overrides`,
        # and the `use Bond` opts. `Bond.Compiler.__before_compile__/1` reads the final
        # `@__bond_contract_config__` attribute when emitting contract overrides.
        @__bond_contract_config__ Bond.Compiler.resolve_config(
                                    __MODULE__,
                                    unquote(use_opts),
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
      end

    # `at_annotations: true` (default): shadow `Kernel.@/1` with Bond's `@/1` and import only
    #   the `@` macro plus `check`. The bare `pre`/`post`/`invariant` macros are deliberately
    #   left out of the import list so they never collide with user function names.
    # `at_annotations: false`: leave `@` alone (so libraries like Norm can own it), import only
    #   `check`, and rely on fully-qualified `Bond.pre`/`Bond.post`/`Bond.invariant` calls.
    imports_ast =
      if at_annotations? do
        quote do
          import Kernel, except: [@: 1]
          import Bond, only: [@: 1, check: 1, check: 2, defcontract: 1, defcontract: 2]
        end
      else
        quote do
          import Bond, only: [check: 1, check: 2, defcontract: 1, defcontract: 2]
        end
      end

    hooks_ast =
      quote do
        @on_definition Bond.Compiler
        @before_compile Bond.Compiler
        @after_compile Bond.Compiler
      end

    quote do
      unquote(config_ast)
      unquote(imports_ast)
      unquote_splicing(behaviours_ast)
      unquote(hooks_ast)
    end
  end

  @doc """
  Override `Kernel.@/1` to support `@pre` and `@post` annotations.

  See the `Bond` module docs for the syntax of `@pre` and `@post` annotations.
  """
  defmacro @pre_or_post

  # `@pre`/`@post` with a leading `where(...)`/`whenever(...)` destructuring binding (#47).
  # `where(pattern = source)` asserts the shape (a non-match is a violation); `whenever(pattern
  # <- source)` is conditional (a non-match is vacuously satisfied). The remaining arguments are
  # the scoped assertions — bare and/or a trailing keyword list of `label: assertion`, exactly
  # like a normal `@pre`/`@post` body — and may use Bond's full assertion syntax on the names the
  # pattern binds. Matched before the single-arg and arity-error clauses so that a bare
  # `@post where(...)` (no body) is diagnosed here rather than expanding an undefined `where`.
  defmacro @{pre_or_post, meta, [{binder, _, [binding]} | scoped]}
           when pre_or_post in [:pre, :post] and binder in [:where, :whenever] do
    register_binding_form(pre_or_post, binder, binding, scoped, __CALLER__, meta)
  end

  # This clause handles either "bare" @pre or @post assertions that do not have a label
  # attached to them, or keyword lists where the keys are labels and the values are the
  # assertions.
  defmacro @{pre_or_post, meta, [expression]} when pre_or_post in [:pre, :post] do
    register_pre_or_post(pre_or_post, expression, __CALLER__, meta)
  end

  # `@pre_weaken` / `@post_strengthen` — Eiffel-style refinement of a contract inherited from a
  # `Bond.Behaviour` callback or `Bond.Protocol` function (#16). Same single-arg / keyword-list
  # shape as `@pre`/`@post`; the assertion is registered tagged with its refinement role so the
  # inheritance merge *folds* it (precondition weakened with `or`, postcondition strengthened with
  # `and`) instead of rejecting it. Plain `@pre`/`@post` on an inherited operation stays a compile
  # error. Refinement expressions reference the abstraction's canonical argument names (the
  # callback's or protocol function's), the same vocabulary as the inherited contract.
  defmacro @{refinement, meta, [expression]}
           when refinement in [:pre_weaken, :post_strengthen] do
    register_refinement(refinement, expression, __CALLER__, meta)
  end

  # The positional label forms `@pre <label>, <expr>` and `@pre <expr>, <label>` were removed
  # in Bond 1.0 in favour of the single keyword-list form, matching the `check/1`-only labelling
  # decided in 0.16.0. These two clauses match the exact removed shapes (atom/binary label before
  # or after a quoted expression) and raise a migration CompileError, rather than letting them
  # fall through to the generic arity catch-all below (whose message is about a different mistake).
  defmacro @{pre_or_post, _meta, [label, {_, _, _}]}
           when pre_or_post in [:pre, :post] and (is_atom(label) or is_binary(label)) do
    raise CompileError,
      file: __CALLER__.file,
      line: __CALLER__.line,
      description: positional_label_removed_message(pre_or_post)
  end

  defmacro @{pre_or_post, _meta, [{_, _, _}, label]}
           when pre_or_post in [:pre, :post] and (is_atom(label) or is_binary(label)) do
    raise CompileError,
      file: __CALLER__.file,
      line: __CALLER__.line,
      description: positional_label_removed_message(pre_or_post)
  end

  # Catch-all for `@pre`/`@post` with 2+ args that don't match the single-arg form or the
  # removed-positional-label shapes above. The common trip is mixing a bare assertion with a
  # labelled one (`@pre is_binary(x), positive: x > 0`) — Elixir parses that as two args,
  # neither valid for the existing clauses, so it would otherwise fall through to Kernel's
  # `@/1` and die with an unhelpful arity error. Raise a clearer diagnostic here.
  defmacro @{pre_or_post, _meta, [_, _ | _] = args}
           when pre_or_post in [:pre, :post, :pre_weaken, :post_strengthen] do
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
    register_invariant(expression_or_kw_list, __CALLER__, meta)
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
        invariant_arity_error_message(
          "invariant",
          args,
          "@invariant subject.x >= 0, positive: subject.y > 0",
          "@invariant non_negative: subject.x >= 0, positive: subject.y > 0"
        )
  end

  # @state_invariant <expression-or-keyword-list>
  #
  # Declared in a `Bond.Server` module (#34). Constrains the GenServer's state and is checked
  # after every state-transition callback returns. Expressions reference the implicit `state`
  # binding, which Bond.Server rebinds to the new state extracted from each callback's return.
  # Same bare-or-keyword-list shape as `@invariant`. Capturing here (rather than only in
  # `Bond.Server`) keeps it on the same `@`-override path as the other annotations; in a module
  # that is not a `Bond.Server`, the captured invariant is simply never consumed.
  defmacro @{:state_invariant, meta, [expression_or_kw_list]} do
    register_state_invariant(expression_or_kw_list, __CALLER__, meta)
  end

  defmacro @{:state_invariant, _meta, [_, _ | _] = args} do
    raise CompileError,
      file: __CALLER__.file,
      line: __CALLER__.line,
      description:
        invariant_arity_error_message(
          "state_invariant",
          args,
          "@state_invariant state.count >= 0, positive: state.total > 0",
          "@state_invariant non_negative: state.count >= 0, positive: state.total > 0"
        )
  end

  # @transition_invariant <expression-or-keyword-list>
  #
  # Declared in a `Bond.Server` module (#34). Relates the prior and next state across a state
  # transition: expressions reference the implicit `old_state` and `new_state` bindings, which
  # Bond.Server binds to the callback's incoming state and the state extracted from its return.
  # Checked across every transition callback except `init/1`/`code_change/3` (re-creations).
  defmacro @{:transition_invariant, meta, [expression_or_kw_list]} do
    register_transition_invariant(expression_or_kw_list, __CALLER__, meta)
  end

  defmacro @{:transition_invariant, _meta, [_, _ | _] = args} do
    raise CompileError,
      file: __CALLER__.file,
      line: __CALLER__.line,
      description:
        invariant_arity_error_message(
          "transition_invariant",
          args,
          "@transition_invariant new_state.n >= old_state.n, capped: new_state.n <= 100",
          "@transition_invariant monotonic: new_state.n >= old_state.n, capped: new_state.n <= 100"
        )
  end

  defmacro @{:doc, meta, [value]} do
    Bond.Compiler.register_doc(__CALLER__, meta, value)
    :ok
  end

  # `@apply_contract <ref>` — apply a reusable named contract (`defcontract`) to the next
  # function. A `ref` is `:name` (a contract defined in this module) or `{Module, :name}` (a
  # contract in another module, read via its `__bond_named_contracts__/0` reflection). The
  # contract's pre/postconditions are attached to the function and its parameters are rebound to
  # the contract's canonical names positionally, exactly like an inherited behaviour contract. The
  # applying function's arity selects the overload. v1 applies a single contract per function. See
  # `defcontract`.
  defmacro @{:apply_contract, meta, [expression]} do
    Bond.Compiler.register_apply_contract(expression, __CALLER__, meta)
  end

  defmacro @{:apply_contract, _meta, [_, _ | _]} do
    raise CompileError,
      file: __CALLER__.file,
      line: __CALLER__.line,
      description:
        "@apply_contract accepts a single contract reference — a name (`:withdrawal`) or a " <>
          "`{Module, :name}` pair. Applying multiple contracts to one function is not " <>
          "supported (v1)."
  end

  defmacro @attr do
    # Forward any other module attributes that are not `@pre` or `@post` to `Kernel.@/1`
    quote do
      Kernel.@(unquote(attr))
    end
  end

  @doc """
  Define a reusable, named contract that other functions apply with `@apply_contract`.

  A named contract bundles `@pre`/`@post` under a `{name, arity}` so the same agreement can be
  shared across functions instead of being restated on each one. The head's parameter list
  supplies the contract's *canonical argument names* and their order; a function that applies
  the contract has its parameters rebound to those names positionally (so it may name them
  however it likes), exactly as an implementation inherits a `Bond.Behaviour` callback's
  contract.

      defmodule Money do
        use Bond

        defcontract withdrawal(account, amount) do
          @pre sufficient: amount <= account.balance
          @post non_negative: result.balance >= 0
        end
      end

      defmodule Account do
        use Bond

        @apply_contract {Money, :withdrawal}
        def withdraw(acct, amt), do: %{acct | balance: acct.balance - amt}
      end

  Contracts are keyed by `{name, arity}`, so `name(x)` and `name(x, y)` are distinct overloads;
  the applying function's arity selects which one binds. A contract body may contain only
  `@pre`/`@post`, and each expression may reference only the contract's declared arguments (plus
  `result` in a `@post`).
  """
  defmacro defcontract(head, do: block) do
    Bond.Compiler.NamedContracts.define(head, block, __CALLER__)
  end

  defmacro defcontract(_head, _opts) do
    raise CompileError,
      file: __CALLER__.file,
      line: __CALLER__.line,
      description:
        "Bond: defcontract requires a `do … end` block, e.g. " <>
          "`defcontract name(arg1, arg2) do @pre … end`."
  end

  defmacro defcontract(_head) do
    raise CompileError,
      file: __CALLER__.file,
      line: __CALLER__.line,
      description:
        "Bond: defcontract requires a `do … end` block, e.g. " <>
          "`defcontract name(arg1, arg2) do @pre … end`."
  end

  @doc """
  Register a precondition as a fully-qualified call, for modules that opt out of the
  `@`-prefixed syntax with `use Bond, at_annotations: false`.

  `Bond.pre/1` is the qualified-call equivalent of `@pre`; everything the FSM does with the
  registered assertion is identical. It accepts either a bare assertion expression or a keyword
  list of `label: assertion` pairs. Labels are atoms — quote for spaces or punctuation:

      Bond.pre x > 0
      Bond.pre positive: x > 0, bounded: x < 100
      Bond.pre "x must be positive": x > 0
  """
  defmacro pre(expression) do
    register_pre_or_post(:pre, expression, __CALLER__, line: __CALLER__.line)
  end

  @doc """
  Register a postcondition as a fully-qualified call. See `Bond.pre/1` and the `:at_annotations`
  option of `use Bond` for context; this is the qualified-call equivalent of `@post`.
  """
  defmacro post(expression) do
    register_pre_or_post(:post, expression, __CALLER__, line: __CALLER__.line)
  end

  @doc """
  Weaken an inherited precondition, the qualified-call equivalent of `@pre_weaken` (#16).

  For modules that opt out of the `@`-prefixed syntax with `use Bond, at_annotations: false`.
  The effective precondition becomes `inherited or pre_weaken`; see `Bond.Behaviour` for the
  Eiffel-style refinement rules. Accepts a bare assertion or a keyword list of `label: assertion`
  pairs, exactly like `Bond.pre/1`.
  """
  defmacro pre_weaken(expression) do
    register_refinement(:pre_weaken, expression, __CALLER__, line: __CALLER__.line)
  end

  @doc """
  Strengthen an inherited postcondition, the qualified-call equivalent of `@post_strengthen` (#16).

  See `Bond.pre_weaken/1` and the `:at_annotations` option of `use Bond`. The effective
  postcondition becomes `inherited and post_strengthen`.
  """
  defmacro post_strengthen(expression) do
    register_refinement(:post_strengthen, expression, __CALLER__, line: __CALLER__.line)
  end

  @doc """
  Register an invariant as a fully-qualified call, the qualified-call equivalent of
  `@invariant`. Accepts a bare expression or a keyword list of `label: expression` pairs;
  expressions reference the implicit `subject` binding exactly as in the `@invariant` form.

      Bond.invariant subject.size >= 0
  """
  defmacro invariant(expression_or_kw_list) do
    register_invariant(expression_or_kw_list, __CALLER__, line: __CALLER__.line)
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
  > `check` honours the `:bond, :checks` configuration:
  >
  > - `:purge` — `check` calls in modules that `use Bond` expand to `:ok` at compile time and
  >   the wrapped expression is **not evaluated** at all. Don't rely on side effects in checks.
  > - `true` (default) — `check` calls expand to a runtime-guarded evaluation; the guard reads
  >   the runtime mode for `:checks` on every call and evaluates unless it is `false`.
  > - `false` — same shape as `true`, but the runtime default flips to `false` (off unless
  >   re-enabled).
  >
  > Compile-time defaults come from `config :bond, checks: …` (and `use Bond` opts). To toggle
  > at runtime, use `Bond.Config.enable(:checks)` / `Bond.Config.disable(:checks)` —
  > `Application.put_env/3` after the first contracted call is not picked up. See `Bond.Config`.
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

  # Dispatch a bare assertion or each `label: assertion` entry of a keyword list to `register`,
  # which is called as `register.(expression, label)`. The shared shape behind every `@`-annotation
  # registration helper below. Returns `:ok` so the calling macro expands to a harmless no-op.
  defp register_each(expression_or_kw_list, register) do
    if Keyword.keyword?(expression_or_kw_list) do
      for {label, expr} <- expression_or_kw_list, do: register.(expr, label)
    else
      register.(expression_or_kw_list, nil)
    end

    :ok
  end

  # Shared by the `@pre`/`@post` single-argument clause and the qualified `Bond.pre/1` /
  # `Bond.post/1` macros. Registers a bare assertion or each `label: assertion` pair into the
  # per-module FSM.
  defp register_pre_or_post(pre_or_post, expression, caller, meta) do
    register_each(expression, fn expr, label ->
      Bond.Compiler.register_assertion(pre_or_post, expr, label, caller, meta)
    end)
  end

  # `@pre`/`@post where(...)`/`whenever(...)` (#47): parse + validate the binding clause, collect
  # the scoped assertions, and hand them to `Bond.Compiler.register_binding_group/7` to register
  # as one binding group.
  defp register_binding_form(pre_or_post, binder, binding, scoped, caller, meta) do
    {mode, pattern, source} = parse_binding!(binder, binding, caller)
    assertions = parse_scoped_assertions!(binder, scoped, caller)

    Bond.Compiler.register_binding_group(
      pre_or_post,
      mode,
      pattern,
      source,
      assertions,
      caller,
      meta
    )
  end

  # The keyword fixes the arrow, so the two reinforce each other: `where` => `=` (assert the
  # shape) and `whenever` => `<-` (conditional). A mismatched pair — or a non-binding argument —
  # is a compile error.
  defp parse_binding!(:where, {:=, _, [pattern, source]}, _caller), do: {:assert, pattern, source}

  defp parse_binding!(:whenever, {:<-, _, [pattern, source]}, _caller),
    do: {:conditional, pattern, source}

  defp parse_binding!(binder, binding, caller) do
    {arrow, example} =
      if binder == :where,
        do: {"=", "where(pattern = source)"},
        else: {"<-", "whenever(pattern <- source)"}

    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "`#{binder}` requires a `pattern #{arrow} source` binding, e.g. `#{example}`. " <>
          "Got: #{Macro.to_string(binding)}. (`where` uses `=` and asserts the shape; " <>
          "`whenever` uses `<-` and is conditional.)"
  end

  # The scoped assertions of a `where`/`whenever` form: the args after the binding, handled
  # exactly like a normal `@pre`/`@post` body — bare positional assertions and/or a trailing
  # keyword list of `label: assertion`. Returns `[{label, expression}]` with `label` `nil` for a
  # bare assertion. At least one is required (a bare shape check is `<~`).
  defp parse_scoped_assertions!(binder, [], caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "`#{binder}` needs at least one assertion after the binding. For a bare shape check " <>
          "with no further assertions, use `<~` instead, e.g. `@post {:ok, _} <~ result`."
  end

  defp parse_scoped_assertions!(_binder, scoped, _caller) do
    Enum.flat_map(scoped, fn arg ->
      if Keyword.keyword?(arg) do
        Enum.map(arg, fn {label, expr} -> {label, expr} end)
      else
        [{nil, arg}]
      end
    end)
  end

  # Shared by the `@pre_weaken`/`@post_strengthen` clause and the qualified `Bond.pre_weaken/1` /
  # `Bond.post_strengthen/1` macros. Registers each assertion tagged with its refinement role so
  # `Bond.Compiler.merge_inherited_contract/2` folds it into the inherited contract.
  defp register_refinement(refinement, expression, caller, meta) do
    kind = refinement_kind(refinement)

    register_each(expression, fn expr, label ->
      Bond.Compiler.register_assertion(kind, expr, label, caller, meta, refinement)
    end)
  end

  defp refinement_kind(:pre_weaken), do: :precondition
  defp refinement_kind(:post_strengthen), do: :postcondition

  # Shared diagnostic for the 2+-arg `@invariant` / `@state_invariant` / `@transition_invariant`
  # shape (a bare expression mixed with labelled ones, which parses as multiple args). `bare` and
  # `labelled` are annotation-specific example fixes.
  defp invariant_arity_error_message(annotation, args, bare, labelled) do
    "@#{annotation} accepts a single argument — either a bare expression or a keyword list of " <>
      "label: expression pairs. Got #{length(args)} arguments (likely a bare expression mixed " <>
      "with labelled ones, e.g. `#{bare}`). Either label every expression (`#{labelled}`) or use " <>
      "a separate @#{annotation} line per bare expression."
  end

  # Migration diagnostic for the positional `@pre`/`@post` label forms removed in Bond 1.0.
  defp positional_label_removed_message(pre_or_post) do
    "@#{pre_or_post} <label>, <expr> and @#{pre_or_post} <expr>, <label> (the positional " <>
      "label forms) were removed in Bond 1.0. Use the keyword-list form instead: " <>
      "`@#{pre_or_post} <label>: <expr>`. Labels are atoms — quote for spaces or " <>
      "punctuation, e.g. `@#{pre_or_post} \"must be positive\": x > 0`."
  end

  # Shared by the `@invariant` single-argument clause and the qualified `Bond.invariant/1` macro.
  defp register_invariant(expression_or_kw_list, caller, meta) do
    register_each(expression_or_kw_list, fn expr, label ->
      Bond.Compiler.register_invariant(expr, label, caller, meta)
    end)
  end

  # `@state_invariant` (#34, `Bond.Server`).
  defp register_state_invariant(expression_or_kw_list, caller, meta) do
    register_each(expression_or_kw_list, fn expr, label ->
      Bond.Compiler.register_state_invariant(expr, label, caller, meta)
    end)
  end

  # `@transition_invariant` (#34, `Bond.Server`).
  defp register_transition_invariant(expression_or_kw_list, caller, meta) do
    register_each(expression_or_kw_list, fn expr, label ->
      Bond.Compiler.register_transition_invariant(expr, label, caller, meta)
    end)
  end

  # Build the AST for a `check` call honouring the per-module `:checks` config:
  #
  #   * `:purge` — expand to `:ok` at compile time; `build_inline_ast` is never called and
  #     the wrapped expression is not evaluated at runtime.
  #   * `true` / `false` — call `build_inline_ast` with the compile-time-resolved mode to
  #     produce the call(s) to `Bond.Runtime.Eval.evaluate_check/2`. The runtime guard
  #     (a `:persistent_term` read defaulting to the compile-time mode) lives inside `Eval`.
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
