# Guarantees

Compile-time bug-class prevention, demonstrated with concrete vignettes. Each entry shows a real-world scenario, the naive code that compiles in mainstream languages and breaks in production, the compile error dilang produces, and the redesign the compiler forces.

The point is to *demonstrate* — not assert — the language's claims. Where `design.md` argues from principles and `decisions.md` records what was chosen, this dimension shows what each guarantee actually catches.

## How to read each vignette

Every entry follows the same five-section structure:

1. **Scenario** — one paragraph setting up the real-world situation.
2. **The bug** — naive code that compiles in Python / Node / Go and breaks in production.
3. **What dilang says** — the compile error, with the line it points at and the design section it cites.
4. **The forced redesign** — the code the compiler makes you write instead.
5. **What discipline alone can't catch** — the failure modes that collapse into one type error.

A good vignette fits in roughly 250 lines including code. Beyond that, split into two.

## Preliminary syntax note

Some vignettes use the proposed `with [ ... ] @ Scope { body }` form rather than the current `provide @ Scope { ... } in { body }` directive. The semantics are unchanged — translate freely:

```
with [ Cap = expr, ... ] @ Scope { body }
↔
provide @ Scope { Cap = expr ... } in { body }
```

The with-form is preferred in new vignettes for readability. When the surface syntax stabilises in a future DEC, vignettes will be updated wholesale.

## Index

### By bug class

| Bug class                       | Vignettes |
|---------------------------------|-----------|
| Cross-context state leak        | [01](./01-job-vs-request-scope.md), [02](./02-cross-tenant-leak.md) |
| Resource lifetime violation     | [03](./03-transaction-escape.md) |
| Silent API drift                | *planned* |
| Unhandled-error escape          | *planned* |
| Capability escape (sandbox)     | *planned* |

### By feature

| Feature                            | Vignettes |
|------------------------------------|-----------|
| Scopes (`@ X`)                     | [01](./01-job-vs-request-scope.md), [02](./02-cross-tenant-leak.md), [03](./03-transaction-escape.md) |
| `Lifecycle` (start/shutdown)       | [02](./02-cross-tenant-leak.md), [03](./03-transaction-escape.md) |
| Closure `requires` rows            | [03](./03-transaction-escape.md) |
| `pub` row exactness                | *planned* |
| `raises` rows                      | *planned* |
| `defer`                            | *planned* |
| Construction/call split (DEC-009)  | *planned* |
| Impl private `requires`            | *planned* |

### Planned

| #  | Title                                          | Catches |
|----|------------------------------------------------|---------|
| 04 | Public function row drift                      | declared `requires` / `raises` row diverges from body |
| 05 | Error variants escaping `try/catch`            | unhandled variant escapes without re-declaring |
| 06 | Forgotten cleanup on cancellation              | `defer` / `Lifecycle.shutdown` not run on cancel path |
| 07 | Renaming a struct to a function                | call sites silently keep working with wrong semantics |
| 08 | Impl private `requires` leaking                | implementation's internal `IO` requirement spreading to callers |
| 09 | Sandbox capability escape                      | plugin code names a cap outside the narrowed set (forward-looking) |

The index doubles as a coverage matrix. Empty rows mean either a missing demonstration or a missing guarantee — both worth knowing.

## Adding a new vignette

1. Pick a (bug class, feature) pair from the gaps above, or propose a new one.
2. Number sequentially: `NN-short-slug.md`.
3. Follow the five-section structure.
4. Add a row to both the "by bug class" and "by feature" tables.
5. Cross-reference design and decisions: `design §X.Y.Z`, `DEC-NNN`.
6. Keep code self-contained — readers should not need to flip to other files.
