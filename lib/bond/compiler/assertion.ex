defmodule Bond.Compiler.Assertion do
  @moduledoc internal: true
  @moduledoc """
  Struct representing an assertion that appears as part of contract specifications, such as in
  preconditions or postconditions attached to functions.

  Assertions are constructed at compile-time and as such the fields in this struct are quoted
  expressions or compile-time environment data. At run-time, the assertion `:expression` is
  evaluated by unquoting it in the context of the function to which the assertion is attached.
  """

  alias __MODULE__

  @enforce_keys [:id, :expression, :kind, :definition_env, :meta]
  defstruct [
    :id,
    :label,
    :expression,
    :code,
    :kind,
    :definition_env,
    :meta,
    # The behaviour module an inherited contract originated from, or `nil` for a contract
    # declared directly on the function. Set by `Bond.Behaviour` when capturing callback
    # contracts; flows through to the assertion-failure metadata and error structs so a
    # violation can be attributed to the source behaviour.
    :source_behaviour,
    # The named contract an applied `defcontract` assertion came from, as `{module, name}`, or
    # `nil` for an ordinary assertion. Stamped when `@apply_contract` resolution attaches the
    # contract to a function (#35); flows through to the failure metadata and error structs so a
    # violation reads "(from contract Money.withdrawal)".
    :source_contract,
    # The refinement role of an impl-authored assertion that refines an inherited contract:
    # `:pre_weaken` (weakens the inherited precondition — combined with `or`) or
    # `:post_strengthen` (strengthens the inherited postcondition — combined with `and`).
    # `nil` for an ordinary `@pre`/`@post`. Set by `Bond.Compiler.register_assertion/6` from
    # the `@pre_weaken`/`@post_strengthen` macros; consumed by `merge_inherited_contract/2` to
    # partition impl assertions and fold them per the Eiffel variance rules (#16).
    :refinement,
    # The destructuring binding group this assertion is scoped to, or `nil` for an ordinary
    # assertion. A `where`/`whenever` contract form (#47) binds a pattern from a source value and
    # scopes a run of assertions to it; every assertion in that run shares one `binding` map:
    #
    #   %{mode: :assert | :conditional, pattern: Macro.t(), source: Macro.t(), group_id: String.t()}
    #
    # `:assert` (`where`, arrow `=`) makes a non-match a contract violation; `:conditional`
    # (`whenever`, arrow `<-`) makes a non-match vacuously satisfied. `group_id` ties the run's
    # members together so `assertions_eval_list/3` can wrap them in a single `case` over `source`
    # that binds `pattern`'s names for the members. Set by `Bond.Compiler.register_binding_group/6`.
    :binding
  ]

  @type t :: t(Bond.assertion_kind())

  @type t(kind) :: %__MODULE__{
          id: String.t(),
          label: Bond.assertion_label(),
          expression: Bond.assertion_expression(),
          code: String.t(),
          kind: kind,
          definition_env: Macro.Env.t(),
          meta: list(),
          source_behaviour: module() | nil,
          source_contract: {module(), atom()} | nil,
          refinement: :pre_weaken | :post_strengthen | nil,
          binding: binding() | nil
        }

  @typedoc """
  A destructuring binding group shared by every assertion scoped to one `where`/`whenever`
  contract form (#47). See the `:binding` field on `t:t/0`.
  """
  @type binding :: %{
          mode: :assert | :conditional,
          pattern: Macro.t(),
          source: Macro.t(),
          group_id: String.t()
        }

  @type function_info :: {atom(), non_neg_integer()}

  # An assertion expression must be a quoted Elixir AST node — a 3-tuple
  # of `{head, metadata, args}` where `metadata` is a list and `args` is
  # a list. The head is either an atom (local calls, operators, bare
  # variables) or itself a 3-tuple with `:.` as ITS head (remote calls
  # like `String.starts_with?(x, "foo")` and anonymous-fn invocations).
  # Anything else is not a valid assertion AST and falls through to a
  # user-facing diagnostic raised at the macro layer in `lib/bond.ex`.
  defguard is_assertion_expression(expression)
           when is_tuple(expression) and
                  tuple_size(expression) == 3 and
                  (is_atom(elem(expression, 0)) or
                     (is_tuple(elem(expression, 0)) and
                        tuple_size(elem(expression, 0)) == 3 and
                        elem(elem(expression, 0), 0) == :.)) and
                  is_list(elem(expression, 1)) and
                  is_list(elem(expression, 2))

  @doc """
  Construct a new `t:t/0` struct.

  Each assertion is tagged with a unique random `:id` so that it has a stable identity that
  survives macro expansion. The `:code` field is the human-readable form of the quoted
  `expression`, suitable for inclusion in error messages and generated documentation.
  """
  def new(kind, label, expression, %Macro.Env{} = env \\ __ENV__, meta \\ [])
      when is_assertion_expression(expression) do
    %__MODULE__{
      id: generate_unique_id(),
      kind: kind,
      label: label,
      expression: expression,
      code: Macro.to_string(expression),
      definition_env: env,
      meta: meta
    }
  end

  @doc """
  Returns a copy of `assertion` with `new_expression` in place of its expression, regenerating the
  rendered `code` and assigning a fresh `:id`, while keeping `kind`/`label`/`definition_env`/
  `meta`/source/refinement.

  Used when composing named contracts (#40): an included contract's assertion, with its parameters
  substituted by the host's argument expressions, is a new, distinct materialised assertion (hence a
  fresh id) whose error/doc text should show the substituted form (hence regenerated `code`).
  """
  @spec replace_expression(t(), Bond.assertion_expression()) :: t()
  def replace_expression(%__MODULE__{} = assertion, new_expression)
      when is_assertion_expression(new_expression) do
    %{
      assertion
      | id: generate_unique_id(),
        expression: new_expression,
        code: Macro.to_string(new_expression)
    }
  end

  @doc """
  Tags an assertion with its refinement role (`:pre_weaken` or `:post_strengthen`).

  Used by `Bond.Compiler.register_assertion/6` when an `@pre_weaken`/`@post_strengthen`
  annotation is registered, so `merge_inherited_contract/2` can later partition the impl's own
  assertions from the inherited contract and fold them per the Eiffel variance rules (#16).
  """
  @spec put_refinement(t(), :pre_weaken | :post_strengthen) :: t()
  def put_refinement(%__MODULE__{} = assertion, refinement)
      when refinement in [:pre_weaken, :post_strengthen] do
    %{assertion | refinement: refinement}
  end

  @doc """
  Tags an assertion with the `where`/`whenever` destructuring binding group it belongs to (#47).

  Every assertion scoped to one `where`/`whenever` form shares the same `binding` map; the common
  `group_id` lets `assertions_eval_list/3` wrap the run's members in a single `case` over the
  bound `source`. Used by `Bond.Compiler.register_binding_group/6`.
  """
  @spec put_binding(t(), binding()) :: t()
  def put_binding(%__MODULE__{} = assertion, %{mode: mode, group_id: group_id} = binding)
      when mode in [:assert, :conditional] and is_binary(group_id) do
    %{assertion | binding: binding}
  end

  @doc """
  Validates that `expression` is a valid assertion expression — a quoted Elixir
  AST node satisfying `is_assertion_expression/1`. Returns `:ok` on success;
  raises `CompileError` with `env`'s file/line and a one-sentence diagnostic
  otherwise.

  Called at the macro layer in `lib/bond.ex` (via `Bond.Compiler.register_*`)
  before `new/5`, so the user sees a Bond-shaped error at the assertion site
  instead of an inscrutable `FunctionClauseError` from `new/5` dumping the
  full `Macro.Env`.
  """
  @spec validate_expression!(term(), Macro.Env.t()) :: :ok
  def validate_expression!(expression, %Macro.Env{} = _env)
      when is_assertion_expression(expression) do
    :ok
  end

  def validate_expression!(expression, %Macro.Env{} = env) do
    source = expression_source(expression)

    raise CompileError,
      file: env.file,
      line: env.line,
      description:
        "Bond assertion is not a valid Elixir expression: #{source}. Assertions " <>
          "must be a call or operator expression returning a truthy/falsy value " <>
          "(e.g. `is_integer(x)`, `x > 0`, `Map.has_key?(m, :k)`, " <>
          "`String.starts_with?(s, \"prefix\")`). Bare literals, variables, and " <>
          "non-AST terms aren't valid assertion forms."
  end

  # `Macro.to_string/1` handles literals and AST nodes; fall back to `inspect`
  # for anything pathological.
  defp expression_source(expression) do
    Macro.to_string(expression)
  rescue
    _ -> inspect(expression, limit: 80)
  end

  @doc """
  Returns a quoted block that, when spliced into a function body, evaluates each of the given
  `assertions` in order.

  On the first assertion failure the block throws `{:assertion_failure, info}`, where `info`
  is a map containing enough metadata to construct a `Bond.PreconditionError` /
  `Bond.PostconditionError` / `Bond.CheckError` struct, plus the runtime `binding()` from
  inside the enclosing function.

  `function_info` must be a `{name, arity}` tuple identifying the function the assertions are
  attached to; it is embedded in the error info so error messages can report the calling
  function's MFA.

  The block imports `Bond.Predicates` so operators like `~>` and `|||` are available to
  assertion expressions. It is intended to be used as the body of a `defp` generated by
  `Bond.Compiler.AnnotatedFunction` (one per kind per function) — see that module for the
  call-site shape that invokes the generated defp through `Bond.Runtime.Eval`.
  """
  @spec assertions_body([t()], function_info(), module() | nil) :: Macro.t()
  def assertions_body(assertions, function_info, function_module \\ nil)
      when is_list(assertions) and is_tuple(function_info) do
    quote do
      import Bond.Predicates

      (unquote_splicing(assertions_eval_list(assertions, function_info, function_module)))
    end
  end

  @doc """
  Returns the ordered list of quoted `Bond.Runtime.Eval.check_assertion/3` calls — one per
  assertion — that `assertions_body/3` splices into the lifted assertion defp.

  Exposed separately so the refined-precondition builder (`pre_weaken_body/4`) can compose two
  such lists (the inherited group and the impl's `@pre_weaken` group) into the `or`-combined
  evaluation, each list retaining its own per-assertion identity, telemetry, Dialyzer-laundering,
  and deferred failure binding.
  """
  @spec assertions_eval_list([t()], function_info(), module() | nil) :: [Macro.t()]
  def assertions_eval_list(assertions, function_info, function_module \\ nil)
      when is_list(assertions) and is_tuple(function_info) do
    for %Assertion{expression: expression, definition_env: assertion_env} = assertion <-
          assertions do
      assertion_info = %{
        assertion_id: assertion.id,
        kind: assertion.kind,
        label: assertion.label,
        expression: assertion.code,
        file: assertion_env.file,
        line: assertion_env.line,
        # The MFA module is the module the function is *compiled into* (the implementer for
        # inherited contracts), not where the assertion text was written. They coincide for
        # contracts declared directly on the function, so `function_module` is only passed
        # explicitly for inherited contracts; otherwise fall back to the assertion's env.
        module: function_module || assertion_env.module,
        function: function_info,
        source_behaviour: assertion.source_behaviour,
        source_contract: assertion.source_contract
      }

      # Delegate the truthiness check and throw-on-failure to
      # `Bond.Runtime.Eval.check_assertion/3`, where `result` is typed `term()`. Emitting
      # `if expression do :ok else throw(...) end` directly here would let Dialyzer prove
      # the falsy branch unreachable when the user's expression is statically `true`
      # (e.g. `@pre is_binary(x)` on a `@spec`-narrowed argument), producing Pattern:
      # `false`, Type: `true` warnings in downstream apps.
      #
      # The failure binding is passed as a 0-arity thunk, not an eager `binding()`. A bare
      # `binding()` builds a keyword list of every variable in this defp's scope (the whole
      # parameter list, plus `result` and every `old(...)` capture) on EVERY successful
      # evaluation and discards it unless the assertion fails — ~8 ns per in-scope variable
      # of pure waste on the hot path. Wrapping it in `fn -> binding() end` captures the
      # variables cheaply (pointers, ~1 ns each) but defers the list construction to
      # `check_assertion/3`'s failure clauses, which almost never run. Error contents are
      # identical; see the bench `bench/runtime_check_overhead.exs` decomposition section.
      quote do
        Bond.Runtime.Eval.check_assertion(
          unquote(expression),
          unquote(Macro.escape(assertion_info)),
          fn -> binding() end
        )
      end
    end
  end

  @doc """
  Builds the lifted precondition defp body for a *weakened* (refined) precondition (#16):
  `inherited OR @pre_weaken`.

  The inherited group and the impl's weakening group each become a 0-arity thunk wrapping their
  own `assertions_eval_list/3` conjunction; `Bond.Runtime.Eval.evaluate_pre_weaken/3` tries the
  inherited group first and only falls through to the weakening group if it fails. Both groups
  reference the abstraction's canonical argument names — the same names the lifted defp binds as
  its parameters — so no name-binding prelude is needed.
  """
  @spec pre_weaken_body([t()], [t()], function_info(), module() | nil) :: Macro.t()
  def pre_weaken_body(inherited, weaken, function_info, function_module \\ nil)
      when is_list(inherited) and is_list(weaken) and is_tuple(function_info) do
    inherited_eval = assertions_eval_list(inherited, function_info, function_module)
    weaken_eval = assertions_eval_list(weaken, function_info, function_module)
    combined_info = pre_weaken_combined_info(inherited, weaken, function_info, function_module)

    quote do
      import Bond.Predicates

      Bond.Runtime.Eval.evaluate_pre_weaken(
        fn -> (unquote_splicing(inherited_eval)) end,
        fn -> (unquote_splicing(weaken_eval)) end,
        unquote(Macro.escape(combined_info))
      )
    end
  end

  @doc """
  Builds the lifted postcondition defp body for a *strengthened* (refined) postcondition (#16):
  `inherited AND @post_strengthen`.

  Strengthening is plain conjunction, so the inherited group and the impl's strengthening group are
  evaluated in sequence (each throws on its first failing assertion). Both groups reference the
  abstraction's canonical argument names (and `result`), exactly as for `pre_weaken_body/4`.
  """
  @spec post_strengthen_body([t()], [t()], function_info(), module() | nil) :: Macro.t()
  def post_strengthen_body(inherited, strengthen, function_info, function_module \\ nil)
      when is_list(inherited) and is_list(strengthen) and is_tuple(function_info) do
    inherited_eval = assertions_eval_list(inherited, function_info, function_module)
    strengthen_eval = assertions_eval_list(strengthen, function_info, function_module)

    quote do
      import Bond.Predicates

      (unquote_splicing(inherited_eval))

      (unquote_splicing(strengthen_eval))
    end
  end

  # The single combined failure info for a weakened precondition where BOTH the inherited group and
  # the weakening group failed. Shaped like an ordinary precondition `assertion_info` so
  # `Bond.Runtime.Eval.evaluate_assertions/2` raises a `Bond.PreconditionError` unchanged. The
  # rendered expression shows both halves; attribution falls back to the inherited group's
  # `source_behaviour` so the message reads "(inherited from …)". `:binding` is added at runtime by
  # `evaluate_pre_weaken/3` from the weakening group's failure.
  defp pre_weaken_combined_info(inherited, weaken, function_info, function_module) do
    anchor = List.first(inherited) || List.first(weaken)

    inh_codes = inherited |> Enum.map(& &1.code) |> Enum.join(" and ")
    weaken_codes = weaken |> Enum.map(& &1.code) |> Enum.join(" and ")

    source_behaviour =
      case inherited do
        [%__MODULE__{source_behaviour: sb} | _] -> sb
        _ -> nil
      end

    %{
      assertion_id: generate_unique_id(),
      kind: :precondition,
      label: :refined_precondition,
      expression: "(#{inh_codes}) or (#{weaken_codes})",
      file: anchor.definition_env.file,
      line: anchor.definition_env.line,
      module: function_module || anchor.definition_env.module,
      function: function_info,
      source_behaviour: source_behaviour
    }
  end

  @doc """
  Returns a quoted block intended to be used as the body of the lifted private function
  that evaluates module-scoped `@invariant`s.

  `subject` is declared local to the body via `subject = bond_invariant_value`, so each
  invariant's expression (which references `subject`) resolves to the value being
  checked. On the first failure the block throws `{:assertion_failure, info}` with
  `:kind => :invariant`, mirroring `assertions_body/2`'s shape for `@pre`/`@post`.

  `function_info` is the `{name, arity}` of the function the invariant is being checked
  around. Both the pre-invariant check (on entry, value = arg) and the post-invariant
  check (on exit, value = extracted return) share this same defp.
  """
  @spec invariants_body([t(:invariant)], function_info()) :: Macro.t()
  def invariants_body(invariants, function_info)
      when is_list(invariants) and is_tuple(function_info) do
    subject_var = Macro.var(:subject, nil)

    invariants_eval =
      for %Assertion{
            kind: :invariant,
            expression: expression,
            definition_env: env
          } = invariant <- invariants do
        assertion_info = %{
          assertion_id: invariant.id,
          kind: :invariant,
          label: invariant.label,
          expression: invariant.code,
          file: env.file,
          line: env.line,
          module: env.module,
          function: function_info
        }

        # See the corresponding comment in `assertions_body/2` — the if/throw lives in
        # `Bond.Runtime.Eval.check_assertion/3` so Dialyzer can't prove the falsy branch
        # unreachable for tautological invariants, and the failure binding is deferred via a
        # `fn -> binding() end` thunk so the snapshot is only built when an invariant fails.
        quote do
          unquote(subject_var) = var!(bond_invariant_value)

          Bond.Runtime.Eval.check_assertion(
            unquote(expression),
            unquote(Macro.escape(assertion_info)),
            fn -> binding() end
          )
        end
      end

    quote do
      import Bond.Predicates

      (unquote_splicing(invariants_eval))
    end
  end

  @doc """
  Returns a quoted block intended to be used as the body of a 0-arity closure passed to
  `Bond.Runtime.Eval.evaluate_check/2`.

  On success the block evaluates to the value of the assertion expression (so that callers of
  `Bond.check/1,2` continue to receive the expression's value back). On failure it throws
  `{:assertion_failure, info}`, mirroring the shape used by `assertions_body/2` for
  `@pre`/`@post`; the throw is caught by `Bond.Runtime.Eval` and re-raised as a
  `Bond.CheckError`.
  """
  @spec check_body(t(:check)) :: Macro.t()
  def check_body(
        %__MODULE__{kind: :check, expression: expression, definition_env: env} = assertion
      ) do
    assertion_info = %{
      assertion_id: assertion.id,
      kind: :check,
      label: assertion.label,
      expression: assertion.code,
      file: env.file,
      line: env.line,
      module: env.module,
      function: env.function
    }

    # `check_value/3` returns the expression's value on success (so `check expr` evaluates
    # to `expr`'s value) and throws on failure, with the same Dialyzer-laundering motivation
    # as `check_assertion/3`. The failure binding is deferred via a `fn -> binding() end`
    # thunk: `check/1` runs inline in the user's function, so a bare `binding()` would snapshot
    # the user's ENTIRE local scope on every check — the thunk builds it only on failure.
    quote do
      import Bond.Predicates

      Bond.Runtime.Eval.check_value(
        unquote(expression),
        unquote(Macro.escape(assertion_info)),
        fn -> binding() end
      )
    end
  end

  @id_chars ~c"0123456789abcdefghijklmnopqrstuvwxyz"

  defp generate_unique_id do
    for _ <- 1..32, into: "", do: <<Enum.random(@id_chars)>>
  end

  defimpl String.Chars do
    def to_string(%Bond.Compiler.Assertion{label: label, expression: expression, kind: kind}) do
      "#{kind}(#{inspect(label)}) => #{Macro.to_string(expression)}"
    end
  end
end
