# Bond: shared and inherited contracts

Three ways to state a contract once and enforce it in many places. Reach for them in this order:
a **behaviour** or **protocol** when the thing you are describing is a family of implementations,
a **named contract** when the same agreement governs several unrelated functions.

## Behaviours

Declare on the `@callback`, opt in from the implementation:

```elixir
defmodule Ledger do
  use Bond.Behaviour

  @pre positive_amount: amount > 0
  @post non_negative: result >= 0
  @callback withdraw(balance :: non_neg_integer, amount :: pos_integer) :: non_neg_integer
end

defmodule BankAccount do
  use Bond, behaviours: [Ledger]     # emits @behaviour for you — don't write it separately

  @impl true
  def withdraw(bal, amt) when amt <= bal, do: bal - amt
end
```

`BankAccount.withdraw/2` now enforces both, with no contract code in it. Violations read
`precondition (inherited from Ledger) failed for call to BankAccount.withdraw/2`, and the error
struct carries `:source_behaviour`.

**Four rules that bite:**

1. **The contract goes ABOVE the `@callback` it constrains.** Bond attaches `@pre`/`@post` to the
   *following* callback. Written underneath, the contract is absorbed by the **next** callback —
   and if the two callbacks happen to share a parameter name, it compiles silently and enforces
   against the wrong function. The only signal in the observed case was an unused-variable
   warning naming a *generated* function in the *implementing* module, at line 1, for a mistake
   made in a different file.

2. **`use Bond, behaviours: [...]` is the only entry point.** A bare `@behaviour TheBehaviour`
   compiles and inherits **nothing** — silently uncontracted. This is the easier mistake to make,
   because `@behaviour` is what Elixir itself asks for.

3. **Write remote calls fully qualified.** An inherited contract is stored as an expression and
   expanded **in each implementing module**. Argument names rebind positionally, but everything
   else — remote calls, struct literals, `__MODULE__` — resolves in the *implementer's* alias
   scope. An `alias` at the declaration site does not travel with the contract:

   ```elixir
   @post fresh: Tokens.fresh?(result)                    # ❌ resolves in each implementer
   @post fresh: Providers.Tokens.fresh?(result)          # ✅
   ```

   The failure lands a long way from the cause: a warning about an undefined function, naming a
   generated function in a file that does not contain the contract, and at runtime a
   `Bond.AssertionEvaluationError`. Nothing in it says "inherited contract". A corroborating hint
   *is* available at the declaration site — an alias used only inside a contract is reported as
   `unused alias`. If you see that on a behaviour, a short name in a contract is about to fail
   somewhere else.

4. **Contracts reference the callback's argument names**, which become canonical for each
   position. Your implementation may name its parameters however it likes.

### Refinement

By default an implementation inherits **verbatim**, and attaching a plain `@pre`/`@post` to an
inherited operation is a compile error — strengthening a precondition would break
substitutability, and adding a postcondition silently would be refinement by the back door.

To refine deliberately, following Eiffel's variance rules:

```elixir
@impl true
@pre_weaken small_withdrawal: amount == 0        # effective pre  = inherited OR this
@post_strengthen audited: log_exists?(result)    # effective post = inherited AND this
def withdraw(bal, amt), do: ...
```

Refinement expressions reference the **abstraction's** argument names, not your parameters.
`@pre_weaken` requires an inherited precondition to weaken (you may not introduce one);
`@post_strengthen` may add where the callback declared none. `old/1` is available in an inherited
`@post` but not in `@post_strengthen`.

For an implementation-specific assertion that is *independent* of the contract, use `check/1` in
the body — it sits outside the contract chain.

> If a `@post_strengthen` seems inert, an inner callee's own `@post` is probably catching the
> value first. Postconditions are checked **inner-first**.

## Protocols

Same syntax, different enforcement point — the contract wraps **dispatch**, so implementations
need zero Bond awareness:

```elixir
defprotocol Sized do
  use Bond.Protocol

  @post non_negative: result >= 0
  @spec size(t) :: non_neg_integer()
  def size(data)          # name the argument `data`, not `t`
end

defimpl Sized, for: List do
  def size(list), do: length(list)     # completely ordinary
end
```

Applies to every implementation including third-party ones, survives consolidation, and the error
carries `:source_protocol` and `:impl`.

Three limits: a **direct call to the implementation module** (`Sized.List.size/1`) bypasses
dispatch and is not checked; **`old/1` is not supported** in protocol contracts; and
**compile-time `:purge` is not supported** — use runtime configuration.

Implementations may refine by adding `use Bond.Protocol.Impl` to the `defimpl` block. Plain
`defimpl` blocks are unaffected.

## Named contracts

For an agreement shared by functions that are not implementations of anything:

```elixir
defmodule Money do
  use Bond

  defcontract withdrawal(account, amount) do
    @pre positive: amount > 0
    @pre sufficient: amount <= account.balance
    @post non_negative: result.balance >= 0
  end
end

defmodule Account do
  use Bond

  @apply_contract {Money, :withdrawal}     # or :name for a same-module contract
  def withdraw(acct, amt), do: %{acct | balance: acct.balance - amt}
end
```

The head is a canonical signature: it supplies the names the expressions use and the order they
bind in. Parameters rebind **positionally**, so the function may name them differently.

  * **Identified by `{name, arity}`** — same name at different arities are distinct contracts, and
    the applying function's arity selects the overload.
  * **A zero-argument `defcontract name()` is arity-agnostic** and applies to a function of any
    arity. The explicit `()` is required. Preconditions are rejected (there are no argument names
    to reference), so this is the form for a shared return-value guarantee.
  * **Adding your own `@pre`/`@post` alongside is fine** — they are conjoined. But added clauses
    reference the **contract's** argument names, not your function's parameters; referencing your
    own parameter is a compile error.
  * **Compose with `include`**, since a function applies exactly one named contract directly:

    ```elixir
    defcontract order(item) do
      include positive(item.quantity)
      include in_range(item.discount, 0, 100)
    end
    ```

    Each argument is an expression over the host's parameters, substituted into the included
    clauses; error messages show the substituted form. Self-inclusion is a compile error.
  * **`@apply_contract` needs Bond's `@` syntax**, so it is unavailable under
    `at_annotations: false`. `defcontract` works either way.
  * **Mutually exclusive with behaviour inheritance on the same function**, except for
    zero-argument contracts — which are how you strengthen an inherited postcondition by name
    rather than with `@post_strengthen`.

### Is it worth it?

Measured on a real codebase: **15 lines added to remove 1 duplicated line**, and the contract
disappears from the function where a reader is looking for it. Not worth it below several
non-trivial shared clauses. One repeated assertion is a poor reason to skip a contract worth
having — deliberate duplication is fine.

Simpler options first: for a shared *predicate*, just define a public function and call it from
each contract (keep it public — a precondition naming a `defp` is one the caller cannot
discharge). For a shared *label plus expanded expression*, a macro that emits the whole `@pre`
works, and renders the expanded source into errors and docs — but the macro's own module must
`use Bond`, or its `@` is `Kernel`'s and eagerly evaluates the right-hand side, producing a
baffling `undefined variable` error.

## Coexisting with another `@`-overriding library

Norm's `@contract` and Bond both `import Kernel, except: [@: 1]`, so both in one module fails to
compile with `function @/1 imported from both Bond and Norm.Contract`. Pass
`use Bond, at_annotations: false` and write contracts as qualified calls:

```elixir
defmodule Api do
  use Norm
  use Bond, at_annotations: false

  @contract scale(n :: positive_int()) :: positive_int()
  Bond.pre even: rem(n, 2) == 0
  def scale(n), do: n * 2
end
```

The calls sit **before** the `def`, exactly where `@pre` would — they are not in-body statements.
`Bond.pre/1`, `Bond.post/1`, `Bond.invariant/1`, `Bond.pre_weaken/1`, `Bond.post_strengthen/1`;
`check/1` stays available unqualified. These are never imported, so they cannot collide with your
function names.

Function-wrapping libraries (`decorator`, and anything else using `defoverridable` + `super`)
compose fine — Bond detects externally-generated override clauses and wraps the function as a
whole.
