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
