# Language docs

The capability-native language. Dependency injection as a first-class language feature, checked at compile time; the runtime exposed as a capability so user code reads as synchronous without function coloring.

## Read in this order

1. **[design.md](./design.md)** — what the language is for, the principles behind it, and the conceptual model. Numbered paragraphs (legal style: §section.paragraph) for citation in discussions.
2. **[syntax.md](./syntax.md)** — illustrative syntax for every construct. Not a formal grammar; the language is still iterating.
3. **[examples/](./examples/)** — concrete programs putting the pieces together. One file per architectural pattern.
   - [01-layered-backend.md](./examples/01-layered-backend.md) — task-tracker HTTP service in the classic controller/service/repository style.
4. **[guarantees/](./guarantees/)** — what dilang catches at compile time, demonstrated with bug-class vignettes. Each entry: naive code that compiles elsewhere → the compile error → the forced redesign.
   - [01-job-vs-request-scope.md](./guarantees/01-job-vs-request-scope.md) — request-scoped state bleeding into background workers.
   - [02-cross-tenant-leak.md](./guarantees/02-cross-tenant-leak.md) — multi-tenant workers reading/writing the wrong tenant's data.
   - [03-transaction-escape.md](./guarantees/03-transaction-escape.md) — a transaction handle used after COMMIT, directly or via deferred work.
5. **[decisions.md](./decisions.md)** — terse log of design decisions and rejected alternatives, with stable `DEC-NNN` IDs for citation. Consult before re-opening a settled question.
6. **[rfcs/](./rfcs/)** — syntax and semantic change proposals and accepted design records.
   - [RFC-001 — `with` scoped wiring syntax](./rfcs/001-with-scoped-wiring.md) — defines `with [Cap <- expr] @ 'Scope { ... }`, apostrophe lifetime scopes, and `...` Wiring spread.

## Pointing into the docs

When discussing a specific paragraph, use the section path: "§2.3.1 of design" or "syntax §7.4". Examples are referenced by filename and section: "example 01 §10" for the transactions section of the layered backend example.

## Editor support

The [`dilang-zed`](../../dilang-zed/) extension provides Dilang syntax highlighting in [Zed](https://zed.dev). It applies to:

- standalone `.di` files
- fenced code blocks in Markdown tagged with `di`:

````markdown
```di
fn add(a: I64, b: I64) -> I64 { a + b }
```
````

All Dilang snippets in this directory use ` ```di ` fences so the same extension highlights them when these docs are read in Zed.

## Archive

[archive/capability-language-design-v4.md](./archive/capability-language-design-v4.md) — the previous iteration, a single monolithic document. Superseded but useful as historical reference. The main differences in the current iteration:

- The runtime is exposed as a single `IO` capability rather than twelve (`io.Tasks`, `io.Clock`, `io.NetClient`, …). The decomposition is on the deferred list but the single-capability shape keeps examples readable while the conceptual core is being evaluated.
- Goals, syntax, and worked examples live in separate files instead of one long document.
- Paragraphs in the design doc are numbered for citation.
