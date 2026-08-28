# Bond and AI Coding Agents

Bond ships agent-facing rules inside the package — a condensed account of the mechanics, two
sub-rules, and a skill for deciding what a contract should *say*. This guide is for the person
wiring them into an application that uses Bond.

What the rules say is [Bond usage rules](usage-rules.md), published here and readable on its
own. This guide is about getting them in front of your agent.

Nothing here is specific to one agent. Both formats involved are cross-vendor: `AGENTS.md` is
the instruction file most coding agents now read, and `SKILL.md` is the portable skill format —
the same directory works unmodified across the agents that support it, each looking in its own
location. Where a path below has to be concrete it is the default `usage_rules` ships, and the
setting that changes it is named alongside.

## What ships in the package

Four things, all under `deps/bond` after `mix deps.get`. Nothing to download separately, and
they are versioned with the library.

| Path in `deps/bond` | What it is | How it reaches your agent |
| --- | --- | --- |
| `usage-rules.md` | The main rules: setup, syntax, and the traps where the obvious guess is wrong | Inlined or linked in `AGENTS.md` / `CLAUDE.md` |
| `usage-rules/testing.md` | Sub-rule `bond:testing` — proving contracts fire, property testing, coverage | Same |
| `usage-rules/inheritance.md` | Sub-rule `bond:inheritance` — behaviours, protocols, `defcontract` | Same |
| `usage-rules/skills/writing-bond-contracts/` | A skill: what a contract should say, plus a `references/contract-shapes.md` catalogue | Copied into your skills directory |

The split is deliberate. The **rules** are mechanics — an agent needs them in context whenever
it touches Bond code at all. The **skill** is judgement, and only matters while an assertion is
actually being authored, so it loads on demand rather than in every session.

## Setup with `usage_rules`

[`usage_rules`](https://hex.pm/packages/usage_rules) reads a config block in your `mix.exs` and
writes the rules into your agent file and the skill into your skills directory. It is a dev-only
dependency of your application, not of Bond.

```elixir
# mix.exs
def project do
  [
    # ...
    usage_rules: usage_rules()
  ]
end

defp deps do
  [
    {:bond, "~> 1.19"},
    {:usage_rules, "~> 1.2", only: [:dev]}
  ]
end

defp usage_rules do
  [
    file: "AGENTS.md",
    usage_rules: [
      {:bond, sub_rules: []},                                 # inline the main rules
      {:bond, sub_rules: :all, main: false, link: :markdown}  # link the two sub-rules
    ],
    skills: [package_skills: [:bond]]
  ]
end
```

Then:

```sh
mix deps.get
mix usage_rules.sync
```

That writes an `AGENTS.md` of about 30 KB — the main rules inlined, `bond:testing` and
`bond:inheritance` as relative links — and copies the skill, reference file included, into your
skills directory. Set `file:` to whichever instruction file your agent reads, and see
[Where the skill goes](#where-the-skill-goes) for the directory. Commit both, so everyone on the
team and every CI agent gets the same instructions.

`usage_rules` requires Elixir `~> 1.18`. Bond supports `~> 1.16`, so on Elixir 1.16 or 1.17 use
[the manual route](#without-usage_rules) instead.

## Choosing how much to inline

Everything inlined into your agent file is in context for *every* session, whether or not that
session goes near a contract. The three shapes, measured on Bond 1.18:

| `usage_rules:` entry | `AGENTS.md` | What you get |
| --- | --- | --- |
| `:all`, or `[:bond]` | 57.6 KB | Main rules and both sub-rules inlined |
| `[{:bond, sub_rules: []}, {:bond, sub_rules: :all, main: false, link: :markdown}]` | 29.9 KB | Main rules inlined, sub-rules linked |
| `[{:bond, link: :markdown}]` | 482 bytes | All three linked |

The middle row is the recommendation. The main rules cover the traps an agent falls into while
writing any contract at all — [`~>` precedence](writing-sound-assertions.md),
quantifier generators that bind rather than filter, assertion purity — and those need to be
resident. Testing and inheritance are situational: a link costs one line, and the agent opens
the file when the task turns out to need it.

Note that a plain `:bond` entry, and `usage_rules: :all`, both inline the sub-rules too — the
default for a package entry is "all sub-rules". Passing `sub_rules: []` is what pins it to the
main file.

Prefer `link: :markdown` over `link: :at`. Some agents treat an `@path` in the instruction file
as an *import* and pull the file's contents into context on load — Claude Code does — and where
that holds, `link: :at` costs exactly what inlining costs while looking like it doesn't. A
markdown link is a link either way, opened when the agent decides it needs it.

If your agent will not follow a relative path into `deps/`, inline everything instead and accept
the 57.6 KB.

## The skill is not part of `:all`

`usage_rules: :all` discovers `usage-rules.md` and the sub-rules; it skips the `skills/`
directory entirely. The skill arrives only through `skills: [package_skills: [:bond]]`. A
project configured with `usage_rules: :all` and nothing else has the mechanics and none of the
judgement — which is the half that decides whether a contract says anything.

`usage_rules` injects a `managed-by: usage-rules` marker into the copied `SKILL.md`, so a later
sync updates it in place and removes it cleanly if you drop it from config. Content you add
*above* the generated markers is preserved.

### Where the skill goes

The skill is a directory holding a `SKILL.md` and a `references/` file, in the portable Agent
Skills layout. What differs between agents is only where they look for it. `usage_rules`
defaults to `.claude/skills`; point it wherever yours reads:

```elixir
skills: [
  location: "path/your/agent/reads",
  package_skills: [:bond]
]
```

Bond has no opinion about the path, and the skill's content does not change with it.

## Without `usage_rules`

The files are plain Markdown at predictable paths, so nothing here needs a tool. This is the
route on Elixir 1.16 and 1.17, and the route if you would rather not take the dependency.

Add a section to your instruction file — `AGENTS.md`, or whatever your agent reads — pointing
at them:

```markdown
## Bond

This project uses Bond for Design by Contract. Before adding or changing a `@pre`, `@post`,
`@invariant`, or `check/1`, read `deps/bond/usage-rules.md`.

For tests and coverage: `deps/bond/usage-rules/testing.md`
For behaviours, protocols, and `defcontract`: `deps/bond/usage-rules/inheritance.md`
```

If your agent supports imports and you would rather have the main rules resident than fetched,
write that first path in whatever import form it uses — `@deps/bond/usage-rules.md` in Claude
Code — and leave the two sub-rules as plain paths.

And copy the skill into the directory your agent reads:

```sh
SKILLS_DIR=.claude/skills   # whatever your agent uses
mkdir -p "$SKILLS_DIR"
cp -R deps/bond/usage-rules/skills/writing-bond-contracts "$SKILLS_DIR"/
```

A hand-copied skill carries no `managed-by` marker, so nothing will update or clean it up for
you — re-copy it when you upgrade Bond.

## Keeping it current

The rules are versioned with the library and carry version-specific material: which compile-time
diagnostics exist, which invariant heads are actually checked, what a given release added. Rules
synced against 1.15 will quietly under-describe 1.18.

Re-run `mix usage_rules.sync` after `mix deps.update bond`, and commit the diff along with the
lockfile change. If your team has a dependency-upgrade checklist, that is where this belongs.

## One thing the rules cannot do for themselves

The rules tell an agent to add `:bond` to `import_deps` in `.formatter.exs`, but an agent
working in a repo that has not done it will format its own correct code into broken code — the
formatter rewrites Bond's multi-argument binding forms. Do this once, by hand, before you point
an agent at the codebase:

```elixir
# .formatter.exs
import_deps: [:bond]
```

## Checking that it took

In a fresh session, ask the agent to add a contract to a function that has none. What you are
looking for:

  * labelled assertions (`@pre positive: x > 0`) rather than bare expressions;
  * `where` or `whenever` to bind an intermediate value, rather than repeating an expression;
  * a parenthesised consequent on `~>`;
  * the rationale in the function's `@doc`, not in a `#` comment above the contract.

If instead it asks you what Bond's syntax is, or reaches for attribute names Bond does not
have, the rules are not loading — check that the file your agent actually reads is the one
`file:` names, and that the skill landed somewhere your agent looks.

## Related

  * [Bond usage rules](usage-rules.md) — the main rules themselves.
  * [What Should a Contract Say?](what-contracts-say.md) — the same judgement as the skill,
    written for a person.
  * [Testing Contracts](testing-contracts.md) — the human version of `bond:testing`.
  * [Contract Inheritance](contract-inheritance.md) — the human version of `bond:inheritance`.
