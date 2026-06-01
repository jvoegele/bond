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
    :source_behaviour
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
          source_behaviour: module() | nil
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
    assertions_eval =
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
          source_behaviour: assertion.source_behaviour
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

    quote do
      import Bond.Predicates

      (unquote_splicing(assertions_eval))
    end
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
