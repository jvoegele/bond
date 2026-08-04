# Telemetry

Bond emits a telemetry event on every assertion failure, so violations can be
counted, alerted on, and attributed without wrapping anything.


Bond emits a [`:telemetry`](https://hexdocs.pm/telemetry/readme.html)
event whenever a `@pre`, `@post`, `@invariant`, `@state_invariant`,
`@transition_invariant`, or `check` assertion is violated. The event fires once
per failure, immediately before the corresponding `Bond.PreconditionError` /
`Bond.PostconditionError` / `Bond.InvariantError` / `Bond.CheckError` is raised.

**Event:** `[:bond, :assertion, :failure]`

**Measurements:**

- `:system_time` — `System.system_time/0` at the failure
- `:monotonic_time` — `System.monotonic_time/0` at the failure

**Metadata:**

- `:kind` — `:precondition | :postcondition | :invariant | :state_invariant | :transition_invariant | :check`
- `:module` — module the assertion is attached to
- `:function` — `{name, arity}` of the function containing the assertion
- `:label` — the keyword label, or `nil` if unlabelled
- `:expression` — source text of the assertion
- `:assertion_id` — stable per-assertion identifier; the same value
  appears every time the same assertion fails, so it's safe to use as
  an aggregation key
- `:file`, `:line` — source location of the assertion
- `:binding` — sorted snapshot of `binding()` at the failure site

For example, a violated `@pre non_negative_x: x >= 0` on
`BondTest.Math.sqrt(-1)` produces a metadata map of this shape:

```elixir
%{
  kind: :precondition,
  module: BondTest.Math,
  function: {:sqrt, 2},
  label: :non_negative_x,
  expression: "x >= 0",
  assertion_id: "9d8c…",
  file: "/path/to/math.ex",
  line: 15,
  binding: [trap_door: nil, x: -1]
}
```

`:function` is a `{name, arity}` tuple — destructure or call
`elem/2` if you only need one half. The `:assertion_id` is stable
across firings of the same assertion, so it's safe as an
aggregation key in a counter or alerting pipeline.

Attach a handler at application start:

```elixir
:telemetry.attach(
  "bond-failure-logger",
  [:bond, :assertion, :failure],
  &MyApp.Telemetry.log_bond_failure/4,
  nil
)
```

```elixir
defmodule MyApp.Telemetry do
  require Logger

  def log_bond_failure(_event, _measurements, metadata, _config) do
    Logger.warning(
      "bond #{metadata.kind} violated in " <>
        "#{inspect(metadata.module)}.#{elem(metadata.function, 0)}/" <>
        "#{elem(metadata.function, 1)}: #{metadata.expression}"
    )
  end
end
```

Only failure events are emitted. Pass events would be far too chatty for
production use; if there's demand for them they can be added later
behind an opt-in.
