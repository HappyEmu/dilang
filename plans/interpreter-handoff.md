# Handoff: Stage 9 of the Dilang interpreter

This is a **knowledge handover**, not a plan. We will plan Stage 9 properly
in a separate pass — this document just hands you the state, the things
that bit us in Stage 8, and what to expect.

## Where we are

Stages 1–8 are landed and green (**100 tests** across stage1–8, stress,
errors). `dune build && dune runtest` is the gate.

Surface coverage as of Stage 8: `let` / `let mut`, `x = rhs`,
`recv.field = rhs`, `loop` / `while` / `break [v]` / `continue`, `fn` +
`return`, capabilities + `provide ... in`, structs + `impl`, enums + `raise`
/ `try` / `??` / `?.`, `defer` (block-scoped, DEC-012), string interpolation,
arrays `[a, b, c]` + indexed reads/writes `xs[i]`, `for x in xs { ... }`,
and value-method dispatch (`xs.len()`, `xs.push(v)`).

Source of truth, in order of precedence:
- `plans/interpreter.md` — Stage 9 section starts at line 859.
- `docs/lang/syntax.md`, `docs/lang/design.md`, `docs/lang/decisions.md`.

## What Stage 9 adds (one-paragraph rundown)

Strings as a methodable value, riding the `MethodCall` plumbing Stage 8
introduced. The bare set is `.len()`, `.contains(needle)`,
`.starts_with(prefix)`, `.ends_with(suffix)`, `.split(sep) -> [Str]`,
`.trim()`. No string mutation in v0. No char-level operations — `.chars()`
and `s[i]` are deferred. **There are no new AST nodes, no new tokens, no
new parser rules** — Stage 9 is purely a value-method-dispatch extension
plus a tiny string utility. Detailed list and eval sketch live in
`plans/interpreter.md:859`.

## Things to know before you touch anything

These are the load-bearing facts that aren't obvious from the code:

- **Stage 9 is almost entirely an `eval.ml` change.** Specifically,
  `value_method_dispatch` at `lib/eval.ml:394` — that's where `VArray`
  currently lives, and where `VStr` arms slot in alongside. Don't reach
  for parser or AST changes; the plan calls for none, and the existing
  `MethodCall { target; name; args }` already accepts arbitrary expression
  receivers (`"hello".len()` parses today, it just panics at eval).

- **`Stdlib.String.split_on_char` only takes a single char.** Stage 9's
  `.split(sep: Str)` must accept a multi-character separator. Write a
  small `String_util.split_on_substring : string -> string -> string list`
  (~15 lines using `String.index_from`). Mirror that for `.contains`,
  which is just "find substring or not." Put the helper in a new
  `lib/string_util.ml` (no `.mli` needed at this stage; we haven't been
  writing `.mli`s elsewhere — confirm against the rest of `lib/`).

- **Edge cases the plan calls out explicitly** —
  `"".split(sep)` returns `[""]` (one-element array, the empty string).
  `s.split("")` panics with a specific message; "split on empty" is
  ambiguous, and we'd rather a clear failure than a silent
  one-char-per-element fan-out. Write the panic message specific enough
  that a future test can pin it (e.g. `"split: separator must be non-empty"`).

- **`.split` returns `VArray` of `VStr`.** That means the result composes
  with Stage 8 immediately: `s.split(" ")[1]`, `s.split(",").len()`,
  `for p in s.split(",") { ... }`. Add at least one cross-stage test that
  exercises this — Stage 8's parser already accepts `expr[idx]` and
  `expr.method()` chains, so the test mostly verifies eval glue.

- **`MethodCall` has two eval paths; don't unify them.** At
  `lib/eval.ml:224`, the arm checks `Var n when Hashtbl.mem ctx.cap_decls n`
  first and routes to `cap_call`; everything else evaluates the target
  and goes to `value_method_dispatch`. Stage 9 lives entirely in the
  second path. Don't add `VStr` handling to `cap_call`.

- **Parser conflict budget — 6 states, hold the line.** Stage 8 grew the
  count from 3 to 6 (all `atom . LBRACKET` family, all resolve via shift,
  all documented in the addendum below). Stage 9 introduces no parser
  changes, so the count should stay at exactly 6. If you find yourself
  adding a parser rule "for safety" or "to be consistent," stop — the
  plan doesn't ask for it, and `lib/parser.conflicts` will catch the
  regression. Diff `lib/parser.conflicts` before and after; expect zero
  changes.

- **Env shape, defer discipline, `BREAK / RAISE atom`** — unchanged from
  Stage 8. Re-read the Stage 8 handoff (in git, `git show HEAD~1
  -- plans/interpreter-handoff.md` won't show it since this *is* that
  file; use `git log -p plans/interpreter-handoff.md`) if you want the
  full briefing on these. Stage 9 doesn't touch any of them.

- **DEC-014 / DEC-015 (Deferred) remain deferred.** Strings are immutable
  in v0 — there's no `.push_str` or `.replace_in_place` — so neither DEC
  bites on this stage. If you find yourself wanting string mutation,
  push back: it's not on the plan, and adding it now means working
  through the same `mut`-on-receiver-root analysis that DEC-015 parks.

- **Per-test workflow** — `dune build` then
  `./_build/default/bin/main.exe run test/stages/<name>.di` to capture
  output, then write the expect file. Don't hand-write the expected
  output; Stage 7 caught a wrong pre-written defer expectation, and the
  same trap exists for any test that mixes `for` + `defer` + `.split`.

## What bit us in Stage 8 (learn from these)

1. **The plan called for a parser-conflict budget of ≤ 4. We landed at 6.**
   All three new states were the same `atom . LBRACKET` shape in different
   parent contexts — inherent to choosing `[...]` for both array literals
   *and* postfix indexing with no statement terminator. See the addendum
   at the bottom of this file for the long-form analysis and the two
   escape hatches if anyone ever wants the budget back. Lesson: when a
   syntactic choice is inherent (no parser rule reshuffle dodges it),
   document and move on rather than bending precedence pragmas to hide
   it. Stage 9 has no analogous risk because it adds no syntax.

2. **`for n in nums { ... }` triggered a pre-existing latent ambiguity.**
   The struct-literal form `Foo { … }` made the parser unable to tell
   `for n in nums { ... }` from `for n in (nums { ... })` (struct lit
   with field `nums`). Fix was a Rust-style `head_expr` non-terminal —
   a restricted expression form used at the heads of `if` / `while` /
   `for ... in` / `else if`, with struct literals forbidden at the top
   level. This is the same trick Rust uses; it's not a hack, it's the
   designed-in answer. If Stage 9 ever tempts you to add another
   construct that takes an expression followed by `{`, use `head_expr`,
   don't reinvent it. (`head_expr` lives in `lib/parser.mly`.)

3. **`MethodCall` collapsed `CapCall` rather than living alongside it.**
   The first instinct was to keep `CapCall` as-is and add `MethodCall`
   as a separate node. The plan called for collapsing them into one
   AST node with two eval paths, and it was the right call — the
   parser would otherwise have needed to look ahead to decide which
   node to build, and the eval-side branching is cleaner. Stage 9
   doesn't touch this, but the lesson generalises: when a new feature
   *looks* like an existing one at the parser level, prefer one node
   with eval-side routing over two nodes with parser-side disambiguation.

4. **The handoff's expected outputs aren't authoritative.** Same as
   Stage 7. Re-derive expected output from the program every time.

5. **DEC additions cost almost nothing.** Stage 8 landed DEC-015
   (indexed/method-call mutation requires `mut` on receiver root,
   deferred enforcement). Stage 9 may surface its own analogous fork —
   for example, should `.trim()` on an interpolated literal be
   syntactically rejected, or just produce dead work? Drop a DEC entry
   when you make a non-trivial call, even if v0 doesn't enforce it.

## Reporting back

When Stage 9 lands, summarize:
- What runs end-to-end: the canonical string example from
  `plans/interpreter.md:863` plus at least one cross-stage interaction
  (e.g. `for p in s.split(",") { print(p.trim()) }`).
- Whether `lib/parser.conflicts` changed at all (expectation: no — Stage
  9 should touch zero parser rules).
- Whether `String_util` ended up larger than ~15 lines, and if so why
  (multi-byte separators? a regex creep that shouldn't have happened?).
- Any new DEC entries (DEC-016+) and what they're parking.
- One-liner: Stage 9 gives Dilang **string methods on the same
  `MethodCall` machinery as arrays**. Stage 10 follows with closures.

## Out of scope (per `plans/interpreter.md`)

`.chars()`, `s[i]` indexing, Unicode-aware operations, `.replace` /
`.to_lower` / `.to_upper`, `StringBuilder` host type, string `+`
optimisation. Closures (Stage 10), HTTP (Stage 11), scopes / Lifecycle /
Wiring (Stages 12–14), streams (Stage 17).

-----

## Addendum (Stage 8 landed) — parser conflict budget

The Stage 8 plan budgeted **≤ 4** conflict states; the committed parser
ends at **6** (`lib/parser.conflicts`). The over-run is intentional. The
three new states are all the same structural family — `atom . LBRACKET`
at a position where reduce is also valid — instantiated in three
different parent contexts. Default shift wins in each, and shift is the
desired behavior: `xs[0]` is indexing, `break xs[0]` carries an indexed
payload, and `raise X[0]` shifts into an `Index` which the existing
RAISE semantic action then rejects (same outcome the reduce path would
yield). Exact state numbers shift across parser regens; consult
`lib/parser.conflicts` for the current set rather than memorising IDs.

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
baseline. Diff against it on every parser change. Anything beyond 6
needs investigation; Stage 9 in particular should leave it untouched.
