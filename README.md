# Dilang

A capability-native programming language.

Two ideas, one mechanism:

- **Dependency injection as a first-class language feature**, checked at compile time. Services, configuration, and the runtime itself are tracked as **capability rows** in function signatures and bound by lexical `with` blocks. No annotations, no containers, no runtime DI framework.
- **No function coloring.** There is no `async`/`await` and no split standard library. Calls that may suspend look identical to calls that don't, because anything that might suspend goes through a capability (typically `IO`) whose implementation is chosen at `main`.

```di
// Each capability declares which scope it lives in.
scope 'Request under 'Process
scope 'Transaction under 'Process

capability Logger     @ 'Process     { fn info(msg: Str) }
capability RequestCtx @ 'Request     { fn user_id() -> Uuid }
capability DbTx       @ 'Transaction { fn execute(sql: Sql) raises {DbError} }

fn record_visit()
    requires {Logger, RequestCtx, WriteDb}
{
    let uid = RequestCtx.user_id()
    Logger.info("visit from ${uid}")

    // DbTx is bound only inside this Transaction scope; its Lifecycle
    // issues BEGIN on entry and COMMIT (or ROLLBACK) on exit.
    with [
        DbTx <- PgTransaction { conn: WriteDb.acquire() }
    ] @ 'Transaction {
        DbTx.execute(sql"INSERT INTO visits (uid) VALUES (${uid})")
    }
}

fn main() {
    // Process scope: bound once, lives for the program's lifetime.
    with [
        Logger  <- JsonLogger
        WriteDb <- Postgres { url: "localhost" }
    ] @ 'Process {
        serve(8080, |req| {
            // Request scope: a fresh binding per incoming request.
            with [
                RequestCtx <- RequestCtx.fresh(req)
            ] @ 'Request {
                record_visit()
            }
        })
    }
}
```

One mechanism, `with`, wires the database, the logger, the request context, the transaction, and the scheduler. The same code runs in production, in tests (with a deterministic runtime), and on restricted targets like the browser or embedded devices — the difference is just what gets bound at `main`.

Dilang is at the **design/prototype stage**. The repository contains the design documents, illustrative example programs, a small OCaml interpreter prototype, and a Zed editor extension for syntax highlighting.

## Repository layout

- **[`docs/lang/`](./docs/lang/)** — the language. Start at [`docs/lang/README.md`](./docs/lang/README.md), which orders the reading: design → syntax → worked examples → decisions.
- **[`dilang-interpreter/`](./dilang-interpreter/)** — an OCaml tree-walking interpreter prototype with file-backed stage fixtures and HTTP demos.
- **[`playground/`](./playground/)** — small `.di` programs, one per concept (capabilities, errors, wiring composition, request scopes, middleware, streams, transactions, cancellation).
- **[`dilang-zed/`](./dilang-zed/)** — Zed extension. Tree-sitter grammar plus highlight/indent/bracket queries. Highlights standalone `.di` files and ` ```di ` fenced code blocks in Markdown.

The tree-sitter grammar lives in a separate repo, [`HappyEmu/tree-sitter-dilang`](https://github.com/HappyEmu/tree-sitter-dilang), and is tracked here as a submodule under `dilang-zed/tree-sitter-dilang`. Clone with `--recurse-submodules` if you plan to work on the grammar.

## Reading the design

If you're new, read in this order:

1. **[`docs/lang/design.md`](./docs/lang/design.md)** — what the language is for, the principles, the conceptual model. Paragraphs are numbered (§section.paragraph) so they can be cited.
2. **[`docs/lang/syntax.md`](./docs/lang/syntax.md)** — illustrative syntax for every construct. Not a formal grammar; the design is still iterating.
3. **[`docs/lang/examples/01-layered-backend.md`](./docs/lang/examples/01-layered-backend.md)** — a task-tracker HTTP service in the classic controller/service/repository style, exercising most of the language in one place.
4. **[`docs/lang/decisions.md`](./docs/lang/decisions.md)** — terse decision log with stable `DEC-NNN` IDs. Consult before re-opening a settled question.

## Editor support

Install the Zed extension as a dev extension: in Zed, open the command palette and run **`zed: install dev extension`**, then point it at the `dilang-zed/` directory. After install, `.di` files and ` ```di ` Markdown fences are highlighted.
