# Decision log

Stable IDs (`DEC-NNN`) for citation. Each entry: decision, rejected alternatives (one-liner each), cite. Append new entries; never renumber.

Scope: language design only — syntax, semantics, goals. Documentation, tooling, and project-organization choices live elsewhere.

Use this format:

```
## DEC-NNN — Title
Status: Active | Deferred | Superseded by DEC-XXX · Cites: design §X.Y
Decision sentence.
- Rejected: alt — reason
```

-----

## DEC-001 — Single `IO` capability (Zig-style)
Status: Active, split deferred · Cites: design §3.3, §5.2
Model the runtime as one `IO` capability. v4's twelve-capability split is deferred.
- Rejected: keep all twelve — dominates docs; obscures core ideas

## DEC-002 — Wiring composition via `using` directive
Status: Active · Supersedes: v4's `++` / `with` operators · Cites: design §3.5, syntax §7
`provide { using a(), b(), Cap = expr @ Scope } in { ... }`. Lexical order; later wins.
- Rejected: `++` / `with` operators — operator soup; three syntaxes for one concept
- Rejected: unmarked unified `provide { a(), b(), Cap = ... }` — no per-entry signal
- Rejected: `using` as block-level marker — mixing bindings + Wirings needs special-casing

## DEC-003 — Compile-time Wiring check via structural tracing
Status: Active · Cites: design §3.5.4
`Wiring` is opaque at source level; compiler traces function bodies to compute provides/requires. Constraint: binding *sets* must be static; only constructor args may vary.
- Rejected: row-typed `Wiring<provides: {...}, requires: {...}>` — long boundary signatures
- Rejected: no static check — defeats the language's premise

## DEC-004 — `@ ScopeName` mandatory on every binding
Status: Active (carried from v3) · Cites: design §2.8.3
- Rejected: default to `@ Process` — hides scope at binding site

## DEC-005 — No `Result<T, E>`; errors flow through `raises`
Status: Active (carried from v3) · Cites: design §2.5
- Rejected: `Result<T, E>` only — composes poorly with effect rows
- Rejected: both — two error paths is one too many

## DEC-006 — No `?` / `from` for error propagation
Status: Active (carried from v3) · Cites: design §2.5.3
Verbose re-tagging is intentional; keeps domain transitions visible.
- Rejected: `?` operator — hides boundaries

## DEC-007 — No function coloring; runtime via capability
Status: Active (carried from v3) · Cites: design §2.3
- Rejected: colored async — splits the stdlib; the central problem to avoid

## DEC-008 — Capabilities and traits as separate mechanisms
Status: Active (carried from v3) · Cites: design §2.7
- Rejected: unified — conflates dependency resolution with value shape

## DEC-009 — Struct literals use braces; calls use parens
Status: Active · Cites: design §2.9, syntax §1.1, §4.1, §7.2
Struct construction is `Foo { field: value }` (or `Foo` with no braces for fieldless structs). Function calls — including those with named args — are `foo(arg: value)`. The two forms are syntactically distinct at parse time.
- Rejected: unified `Foo(field: value)` for both — shape carries no semantic signal; reviewer must resolve the name to know whether the line allocates data or runs effects. Optimizing for review (most code will be agent-written) means the syntactic split earns its keep.
- Rejected: ban named args on functions — readability at call sites is too valuable to give up; reviewers benefit even more than writers from `connect(host: "...", port: 5432)` over positional.
- Rejected: require `Foo {}` even on empty structs — needless noise. Bare `Foo` constructs a fieldless struct, matching Rust's unit-struct ergonomics.

Implication: named args inside `(...)` always mean a function parameter; named entries inside `{...}` always mean a struct field. Renaming a struct into a fn (or vice versa) with the same name surfaces as a parse-level shape mismatch at call sites, not a silent semantic flip.

## DEC-010 — Function calls: named-args design (Deferred)
Status: Deferred · Cites: design §2.10
A previous version of this decision required every argument after the first to be named at the call site. Reverted after implementation surfaced design ambiguities (mixed positional/named ordering rules, interaction with variadic builtins, param-name renames as silent ABI breaks, scope on capability methods vs user fns). For now: **function and capability-method calls are fully positional.** Struct literals remain named (DEC-009) — that decision stands.

Revisit when the typechecker lands; getting the rule right benefits from having type info to surface mismatches with good error messages.

- Currently active position: fully positional calls. Reviewer-readability is left to writers using local variable names well, until the right named-args shape is figured out.

## DEC-011 — Defer / error interaction (Deferred)
Status: Deferred (v0 interpreter behavior noted) · Cites: syntax §14, design §2.5, §2.10
Two related open questions about how `defer` interacts with `raises`. Park both until `raises` is statically enforced; the answers want type information.

1. **What if a defer body itself raises?** Prior art splits:
   - Zig / Swift: ban at the type level — defer bodies must be unfailable; failing variants (Zig's `errdefer`) replace the in-flight error explicitly.
   - Go: latest panic wins; earlier ones are lost.
   - Interpreter v0 (Stage 6): swallow silently; subsequent defers still run; inner raise does not propagate. Documented in `eval.ml`'s `run_defers`. Chosen to avoid masking the original raise *and* to keep cleanup paths from dropping silently mid-list — but it does drop the inner error.
   Likely landing: Zig's stance. Once `raises` rows are checked, require defer bodies to have an empty `raises` row; lift the v0 swallow to a compile error.
2. **Should `errdefer` exist?** A defer that fires only on error-exit paths, not on normal return. Useful for "undo this allocation if we're bailing out." Easy to slot in once the activation distinguishes exit paths at the type level. Adds one keyword; symmetric with `defer` for the success path. Open whether to also add `successdefer` (D's `scope(success)`) or stop at the two-way split.

- Rejected for v0 (1): propagate inner raise — masks original raise; reviewer can't tell which fired
- Rejected for v0 (1): "last raise wins" — confusing; doesn't compose with multiple defers
- Rejected (preemptively, for the future shape): runtime `recover()` à la Go — §2.10 ("no exception swallowing") is a hard line

## DEC-012 — `defer` is block-scoped
Status: Active · Cites: syntax §14, design §2.5, §2.10
A deferred expression runs at the end of the smallest enclosing `{ ... }`, on every exit path from that block (fall-through, `return`, `break`, `continue`, raised error, cancellation, panic). Each `{ ... }` in the surface syntax is its own defer scope — fn body, `if`/`else` branch, `loop`/`while` body, `try`/`catch` body, `provide ... in` body, bare block expression. Defers within a block fire LIFO. The deferred expression is evaluated at fire time, not at registration (so reads of mutable state see scope-exit values).

Matches Zig / Swift / D `scope(exit)`. Diverges from Go (function-scoped + arguments captured at registration).

- Rejected: function-scoped (Go-style) — turns the obvious `for { defer release(x) }` into a leak that holds N resources until function exit. Forces awkward refactors (extract the loop body into a helper fn). Fails the "deterministic cleanup next to its setup" goal from §2.5 because cleanup runs far from the setup site.
- Rejected: scope-on-keyword-only (`defer` block-scoped, but a separate `func_defer` for function-scoped) — two cleanup keywords doubles the surface area. Function-scoped cleanup is expressible by registering the defer at the top of the fn body, where the scope *is* the function.
- Rejected: per-`try`-only scoping — special-cases one construct; reviewer can't predict scope from the keyword alone.

Interpreter note (Stage 6): implemented by wrapping every block built from `{` ... `}` with `Fun.protect`, with a fresh per-scope `defers` ref swapped onto `ctx`. Activation boundaries (`call_fn`, `DUser`) no longer own defer state — the fn body's own `{ ... }` is the activation's defer scope.

## DEC-013 — `loop` is an expression; `while`/`for` are statements
Status: Active · Cites: syntax §11, design §2.10
`loop { ... }` evaluates to the value carried by `break v` (or `VUnit` if `break;` without value). A `loop` with no reachable `break` has type `Never`. `while cond { ... }` and `for x in xs { ... }` always evaluate to `VUnit` — they may not execute the body at all, so there is no well-defined value to yield.

Matches Rust. The asymmetry is the right call: `loop` is the construct you reach for when you want to compute a result that requires iteration with conditional exit (retry loops, polling), and `break v` is the clean idiom for "here's the answer." `while`/`for` are predicate-driven and the natural return is "done."

- Rejected: all loops statement-shaped (the original Stage-7 plan) — forces an out-of-band mutable binding for "the value the loop computed," which is exactly the pattern `loop`/`break v` exists to remove.
- Rejected: all loops expression-shaped — `while`'s value is undefined when the body never runs; no good answer that doesn't introduce `Option` at every use site.
- Rejected: `break v` allowed in `while`/`for` — only useful when the body runs at least once, and the type checker can't prove that without flow analysis we don't want to require.

Interpreter (Stage 7): `Break_exn` carries an optional value (`Break_exn of value`; bare `break` → `Break_exn VUnit`). The `Loop` arm catches and returns the carried value; `While` / `For` arms catch and discard, returning `VUnit`.

## DEC-014 — Field mutation requires `mut` on the binding (Deferred)
Status: Deferred (v0 interpreter behavior noted) · Cites: design §2.1, §2.10, syntax §1
The eventual rule: `recv.field = rhs` is legal only when `recv` was bound `let mut` (or the field is reached through a chain whose root binding is `mut`). Matches Rust: `let s = Foo{...}; s.field = …` is a compile error; `let mut s = Foo{...}; s.field = …` is fine. Same review-time visibility argument as DEC-002.10's "mutation is visible at the binding site": if `s` is `let` (no `mut`), nothing that follows can mutate the value reachable through it.

Interpreter v0 (Stage 7): **not enforced.** `AssignField` walks straight through the field-as-ref the struct constructor produced (Stage 4) without consulting the binding's `mut` flag, so `let t = Tally{count: 0}; t.count = 1` runs successfully. Documented at the `AssignField` arm in `eval.ml` and at the call sites in `test/stages/07i_mutate_field.di` / `07j_mutate_self_field.di`.

Likely landing: enforce at the parser/typechecker boundary once we have a flow-sensitive way to trace the root binding of an `AssignField`'s receiver chain. Until then, the interpreter accepts more programs than the language definition will eventually allow — programs that rely on this leniency will need a `mut` added to compile under the stricter rule.

- Rejected for v0: enforce in the interpreter now — needs receiver-root tracing through arbitrary expr chains (`a.b.c.d = …`), which is doable but easier with the typechecker's plumbing in place.
- Rejected: drop the rule (allow field mutation on any binding) — contradicts §2.10's "optimize for review: mutation is visible at the binding site." A reader who sees `let s = …` should be entitled to assume nothing downstream mutates state reachable through `s`.

## DEC-015 — Indexed/method mutation requires `mut` on the receiver root (Deferred)
Status: Deferred (v0 interpreter behavior noted) · Cites: design §2.1, §2.10, syntax §1
Companion to DEC-014. The eventual rule: `xs[i] = rhs` and mutating value-method calls (`xs.push(v)`) are legal only when `xs` was bound `let mut` (or the chain's root binding is `mut`). A reader who sees `let xs = …` should be entitled to assume nothing downstream grows or rewrites the array reachable through `xs` — same review-time argument as DEC-014.

Interpreter v0 (Stage 8): **not enforced.** `AssignIndex` writes directly through the `VArray` ref produced by `ArrayLit`, and `VArray.push` mutates the underlying ref regardless of the receiver's `mut` flag. So `let xs = [1, 2, 3]; xs[0] = 99` and `let xs = []; xs.push(1)` both run successfully. Documented at the `AssignIndex` arm and the `VArray, "push"` arm in `eval.ml`, and at the call sites in `test/stages/08e_index_assign.di` / `test/stages/08h_empty_push.di`.

Likely landing: same as DEC-014 — enforce at the parser/typechecker boundary once we have flow-sensitive receiver-root tracing. Programs that rely on this leniency will need a `mut` added.

- Rejected for v0: enforce in the interpreter now — see DEC-014; same tracing problem.
- Rejected: drop the rule — same §2.10 argument as DEC-014.
