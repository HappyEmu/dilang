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
