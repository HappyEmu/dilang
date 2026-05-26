# Handoff: Stage 8 of the Dilang interpreter

This is a **knowledge handover**, not a plan. We will plan Stage 8 properly
in a separate pass — this document just hands you the state, the things
that bit us, and what to expect.

## Where we are

Stages 1–7 are landed and green (**84 tests** across stage1–7, stress,
errors). `dune build && dune runtest` is the gate.

Surface coverage as of Stage 7: `let` / `let mut`, `x = rhs`,
`recv.field = rhs`, `loop` / `while` / `break [v]` / `continue`, `fn` +
`return`, capabilities + `provide ... in`, structs + `impl`, enums + `raise`
/ `try` / `??` / `?.`, `defer` (block-scoped, DEC-012), string interpolation.

Source of truth, in order of precedence:
- `plans/interpreter.md` — Stage 8 section starts at line 758.
- `docs/lang/syntax.md`, `docs/lang/design.md`, `docs/lang/decisions.md`.

## What Stage 8 adds (one-paragraph rundown)

Arrays and iteration: `[a, b, c]` literals, `xs[i]` indexed reads (panic on
OOB in v0), `for x in xs { ... }`, and value-method dispatch for the bare
set `.len()` / `.push(v)`. This is the stage that introduces
`MethodCall { target; name; args }` and the runtime-type-dispatch table on
the target value — Stage 9 (strings) reuses the same plumbing for `.len()`,
`.contains()`, `.split()`, etc. `for` reuses Stage 7's `Break_exn` /
`Continue_exn`. `xs.push(v)` mutates; the AST shape doesn't enforce
`xs : let mut` (DEC-014, see below). Detailed list, eval sketch, and
deferred items live in `plans/interpreter.md:758`.

## Things to know before you touch anything

These are the load-bearing facts that aren't obvious from the code:

- **Parser conflict budget** — 3 states / 14 token resolutions after
  Stage 7. The three states are all `IDENT . (LPAREN | LBRACE)` /
  `IDENT DOT IDENT . LPAREN` / `BREAK . <atom-token>` shape, resolved by
  shift. Stage 5 added the `RAISE atom` trick to dodge a fourth state;
  Stage 7 used the same trick for `BREAK atom?`. Don't reach for `%prec`.
  Run `dune build` and inspect `lib/parser.conflicts` (generated thanks to
  `--explain` in `lib/dune`) to confirm any new conflicts are documented
  and resolved correctly. Adding `xs[i]` (`IDENT . LBRACKET`) is the
  highest-risk addition; factor with shared-prefix rules if needed.

- **`BREAK / RAISE atom`, not `BREAK / RAISE expr`** — `break i * 10` parses
  as `break i` then a stray `* 10`. Callers write `break (i * 10)`.
  Stage 8's `For` body inherits this — `for x in xs { break (x * 2) }`.
  If you add another optional-payload construct, use the same pattern.

- **Block-scoped defer (DEC-012)** — every `{ ... }` is a `Scope` that
  swaps in a fresh `defers` ref and runs them via `Fun.protect`. Activation
  boundaries (`call_fn`, `DUser`) own only the `Return_exn` / `Break_exn` /
  `Continue_exn` catches; the fn body's own `Scope` handles defers.
  `Break_exn` / `Continue_exn` propagating up naturally fire each scope's
  defers on the way out. Stage 8's `For` arm must continue this discipline:
  catch `Break_exn` outside the loop, `Continue_exn` *inside* the per-
  iteration body (same shape as `While` / `Loop`).

- **Env shape** — `env.values : (ident * value ref * bool) list` since
  Stage 7. The `bool` is the per-binding `mut` flag. `Env.extend` takes
  `~mut`; `Env.find_ref` returns the ref + flag (used by `Assign`). Every
  `Env.extend` callsite must pass `~mut:false` unless it's a user `let mut`.
  For Stage 8's `For`, the loop var is bound `~mut:false` per iteration.

- **DEC-014 (Deferred)** — field mutation should eventually require
  `mut` on the receiver's root binding (`let mut t = …; t.field = …`),
  matching Rust. v0 doesn't enforce this. Stage 8's `xs.push(v)` lands
  in the same bucket — `let xs = [...]; xs.push(...)` will run in v0 and
  need a `mut` added when the rule lands. Add the same DEC-014 breadcrumb
  to the relevant `push` arm and test file. Plan documents this under
  "Out of scope at this stage."

- **Value-method dispatch is new** — until Stage 8 the only method-dispatch
  was `CapCall` (`Cap.method(args)`). Stage 8's `MethodCall` is unrelated
  plumbing: dispatch by the target's runtime type (`VArray`, `VStr` from
  Stage 9, future `VStream`), not by capability resolution. Keep the two
  paths distinct in the eval arm — don't try to unify them. Parser hint:
  `target . IDENT ( args )` is the shape; the existing
  `IDENT . IDENT dot_tail` arm doesn't generalise, so `MethodCall` likely
  needs a new atom-level rule that admits a non-IDENT receiver.

- **No semicolons; no unary minus; `Foo {f: v}` for structs and
  `foo(args)` for calls** — unchanged from Stage 1. Array literals
  `[a, b, c]` will need a new LBRACKET / RBRACKET token pair.

- **Per-test workflow** — `dune build` then
  `./_build/default/bin/main.exe run test/stages/<name>.di` to capture
  output, then write the expect file. Don't hand-write the expected
  output; the defer-fire-at-live-env rule (DEC-012) makes that error-prone.
  Stage 7 caught the handoff's pre-written `iter defer 1/2/3/after loop`
  expectation as wrong (actual: `1/2/2/after loop`).

## What bit us in Stage 7 (learn from these)

1. **The Stage 7 eval sketch in the old handoff omitted the per-iteration
   `Continue_exn` catch inside `Loop`.** Following it verbatim makes
   `continue` inside a `loop` surface as "continue outside any loop".
   The `While` arm had it; the `Loop` arm needed it too. Look for similar
   omissions in any sketch you inherit; treat them as starting points, not
   complete code.

2. **Tests with relative-date "expected" values rot.** Capture-at-fire-time
   defer semantics (DEC-012) means writing the expected output by hand is
   a guessing game. Always run the program first, then commit the output.

3. **DEC additions cost almost nothing and save future you.** Stage 7
   surfaced one fork worth recording (DEC-014, field mutation + `mut`).
   Stage 8 has at least one analogous open question — should `push` require
   `let mut xs`? (Yes, eventually; defer enforcement.) Drop a DEC entry
   when you make the call, even if v0 doesn't enforce it.

4. **The handoff's expected outputs aren't authoritative.** Re-derive from
   the program. See item 2.

## Reporting back

When Stage 8 lands, summarize:
- What runs end-to-end (the canonical array example + at least one cross-
  stage interaction, e.g. `for x in xs { defer ...; break }`).
- Whether `MethodCall` introduced new parser conflicts (expectation: zero
  if `target` is restricted to atom-level on the receiver side).
- Whether the `LBRACKET` index syntax conflicts with array literals at
  expression position (e.g. `[1,2,3][0]` parsing).
- Any new DEC entries (DEC-015+) and what they're parking.
- One-liner: Stage 8 gives Dilang **collections and iteration**. Stage 9
  follows with `Str` methods on the same `MethodCall` machinery.

## Out of scope (per `plans/interpreter.md`)

Iterator trait dispatch, `for` over user iterables, slicing, `map` /
`filter` / `fold` (need closures, Stage 10), HTTP, scopes / Lifecycle /
Wiring (Stages 12–14), streams (Stage 17). `pop` / `get` / `insert` /
`remove` only as demos demand.

-----

## Addendum (Stage 8 landed) — parser conflict budget

The Stage 8 plan budgeted **≤ 4** conflict states; the committed parser ends
at **6** (`lib/parser.conflicts`). The over-run is intentional. The three
new states are all the same structural family — `atom . LBRACKET` at a
position where reduce is also valid — instantiated in three different
parent contexts:

- **state 25** — `LBRACE atom . LBRACKET` (block-item boundary)
- **state 102** — `LBRACE BREAK atom . LBRACKET` (break payload boundary)
- **state 129** — `LBRACE RAISE atom . LBRACKET` (raise payload boundary)

Default shift wins in each, and shift is the desired behavior: `xs[0]` is
indexing, `break xs[0]` carries an indexed payload, and `raise X[0]`
shifts into an `Index` which the existing RAISE semantic action then
rejects (same outcome the reduce path would yield).

These conflicts are inherent to the syntactic choices already in the
language: `[...]` for both array literals and postfix indexing, combined
with no statement terminator. Every language with that combination hits
this ambiguity; C / Rust / Go / Python dodge it via mandatory `;` or
significant newlines, JavaScript famously trips on it via ASI. We chose
neither, so the price is paid in the parser tables.

Two paths to bring the budget back, if it ever matters:

1. **Restrict statement-position expressions** — introduce a `stmt_expr`
   non-terminal (mirror of the `head_expr` added in Stage 8) used at the
   block_item lhs and as the BREAK / RAISE payload, with `LBRACKET
   arglist RBRACKET` removed at its top level. Forbids the useless
   standalone `[1,2,3]` statement, kills all three new states. Same
   complexity cost as the existing `head_expr`.
2. **Adopt significant newlines (Go-style ASI)** — lexer becomes stateful
   and emits a synthetic separator after IDENT / literal / `]` / `}` /
   `)` / `return` / `continue` / `break` at line end. Kills these three
   conflicts *and* lets `head_expr` be deleted. Real language-design
   change; warrants its own DEC and a focused stage.

Until then: treat the committed `lib/parser.conflicts` (6 states) as the
new baseline. Diff against it on every parser change. Anything beyond 6
needs investigation; the three Stage-8 additions are *not* a precedent
for accepting further growth.
