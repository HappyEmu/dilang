# Handoff: Stage 3 of the Dilang interpreter

## Where we are

Stages 1 and 2 are landed and green:

- `dilang-interpreter/` is a single Dune project (OCaml 5.2 + Menhir + sedlex + Eio).
- `dilang run <file.di>` evaluates a tree-walked AST and prints to stdout.
- `dune runtest` runs an `alcotest` suite that diffs captured stdout against `expect/<name>.txt`.
- Coverage so far: `fn main()`, `let` (incl. `mut`, declared only), int / string / bool literals, all arithmetic + comparison binops, `print` intrinsic, block-as-expression, shadowing, line comments **(Stage 1)**; multi-argument user function calls, the `return` keyword, and string interpolation `"${expr}"` with `\${` escapes and nested-string-aware brace balancing **(Stage 2)**. Tests: `01_arith`, `01b_full`, `02_functions`, `02b_returns_and_interp`.

Notes worth knowing before touching anything:

- **Parser**: Menhir LR + sedlex. **One** shift/reduce conflict (the `expr`/`atom` one inherited from Stage 1); menhir resolves it by shifting. Confirm the count doesn't grow as you add productions — `dune build` prints the count. If it grows, fix with explicit precedence; don't ignore it. Stage 2 added `%nonassoc RETURN` at the lowest precedence to keep the count at 1; you'll likely need similar precedence reasoning for `provide`/`capability` if you're not careful.
- **Sub-parsing via `expr_entry`**: Stage 2 added a second Menhir start symbol `expr_entry: expr EOF` so the lexer can re-enter the parser to parse embedded sub-expressions inside `${...}`. If Stage 3 ever needs to parse a fragment from inside the lexer again, reuse this pattern (don't add new start symbols casually — each costs a public surface).
- **Block lowering**: parser builds an internal `block_item` list and folds it into nested `Let { ...; body = rest }` and `Block [e; rest]` via `Ast.block_of_items`. Right-leaning. Survives 500k-stmt programs on default macOS stack.
- **Sink abstraction**: `print` writes through `Eval.sink = OutChan of out_channel | Buf of Buffer.t`. CLI uses stdout, tests use a Buffer. Keep this — it'll matter again at Stage 14.
- **Control-flow exceptions**: `exception Return_exn of value` is defined in `eval.ml` and caught **only** in `call_fn`. Stage 3 doesn't add new ones, but if it later does, follow the same pattern: raise inside `eval`, catch at exactly one activation boundary, never in `Block`/`Let`/`Call`.
- **Eio is wired but barely used**: `Driver.run_file` opens `Eio_main.run` + `Eio.Switch.run` before parsing. Nothing depends on it yet. Stage 3 is the first stage that pushes a switch onto the env (one per `provide` frame), so this is where it starts to matter.
- **Top-level fns aren't closures**: `Eval.call_fn` builds a fresh `Env.empty` per activation. Top-level fn lookup is via `ctx.fns : (ident, fn_decl) Hashtbl.t`. Closures arrive at Stage 10. Stage 3 should leave this as-is.
- **No semicolon in the grammar**: items inside a block are separated by whitespace, not `;`. If you write a `.di` test file with `;` it will fail to lex. (The Stage 2 plan had a stray `;` in its stress-test file that I dropped — same caveat applies here.)

## Source of truth

Everything below is *secondary* to:

- [`plans/interpreter.md`](./interpreter.md) — Stage 3 section starts at line 215. Read it before writing code.
- [`docs/lang/syntax.md`](../docs/lang/syntax.md) — §2 (capabilities), §4 (impls), §6 (`requires`/`raises` rows), §7 (provide blocks). The plan trims aggressively; the syntax doc is the spec.
- [`docs/lang/design.md`](../docs/lang/design.md), [`docs/lang/decisions.md`](../docs/lang/decisions.md) — if something's ambiguous, check `decisions.md` first. If it's still ambiguous, ask — don't invent semantics.

## What Stage 3 adds

The plan's example:

```di
capability Logger {
    fn info(msg: Str)
}

fn greet(name: Str) requires {Logger} {
    Logger.info("hello, ${name}")
}

fn main() {
    provide {
        Logger = StdoutLogger() @ Process
    } in {
        greet("world")
    }
}
```

Expected: `hello, world`.

What this stage actually does in the interpreter:

- **`capability Cap { fn m(...) [-> Ret] }` declarations.** Parse and store in a cap table on the program. Default-body methods and `extends` are **Stage 4** — at Stage 3, methods are abstract signatures only.
- **`provide { Cap = expr @ Scope, ... } in { body }`.** A scoped block that pushes a cap frame onto the env, evaluates `body` under it, and pops on exit.
- **`Cap.method(args)` dispatch syntax.** Resolved against the innermost matching frame on the cap stack.
- **`requires {Cap1, Cap2}` on fn declarations.** Parse it. Do not enforce. Lookup at the call site will fail with a clearer message than name-resolution would give.
- **`@ Process` only.** Other scopes are Stage 7. Reject other scope idents at the `provide` site, or accept and ignore — your call, but be consistent. (The plan recommends just defaulting to `"Process"` and treating the annotation as a label.)
- **Host stdlib**: a built-in `StdoutLogger()` constructor that returns an `impl_value` whose `info` method writes to the eval sink (NOT directly to `print_endline` — Stage 1 set up the sink abstraction for good reason; bypassing it breaks test capture).
- **Host-constructor table**: a single map from constructor name (`"StdoutLogger"`) to a function `value list -> impl_value`. Programs invoking `StdoutLogger()` look up this table. User-defined impls / `struct` constructors arrive at Stage 4.

## Stage 3 deliverable

Cut a single commit / PR that:

1. Adds `test/stages/03_logger.di` (the plan's canonical example above) and `test/expect/03_logger.txt` (just `hello, world`).
2. Optionally adds a `03b_*.di` stress test exercising: a `provide` block with multiple cap bindings, a capability with multiple methods, a fn that's called transitively (caller doesn't list `Logger` in `requires`, but resolution still works because the cap is in scope), and an error path (calling a cap that isn't provided — should give a clear `"capability Logger not in scope"`-style failure, not a name-resolution error).
3. Updates `test/run_test.ml` to include `"stage3"`.
4. Passes `dune build && dune runtest` with the shift/reduce conflict count still at **1**.

Don't add anything Stage 4 owns — no user `impl` blocks, no `struct` declarations, no impl-private `requires`, no capability `extends`.

## Out of scope at this stage

- User-defined `impl` blocks and `struct` declarations — Stage 4.
- Capability `extends`, default-body methods on capabilities, impl-private `requires` rows — Stage 4.
- Scopes other than `Process` (`@ Request`, `@ Session`, etc.) and `scope` declarations — Stage 7.
- `Wiring` values (a `provide` with no `in`), `using` composition — Stage 9.
- Lifecycle hooks on impls — Stage 8.
- Closures and lambdas (`|x| ...`), generics syntax `<R, E>` — Stage 10.
- `if`/`else`, `try`, `raise`, `Option`, `?` operator — Stage 5.
- Static row checks of any kind — never, in the interpreter. The type checker is a separate phase.

## Implementation hints

Things that are easy to get subtly wrong:

- **AST**: the long-term shape (from `plans/interpreter.md` §Cross-cutting) is `CapCall { cap; method_; args }` and `Provide { entries; scope; body }` with `provide_entry = Binding of { cap; rhs; scope } | Using of expr list`. At Stage 3 you only need the `Binding` constructor; add `Using` as a stub or skip it entirely until Stage 9 — but if you skip, leave a TODO so Stage 9 can find it.
- **Cap resolution = lexical, innermost wins**. Store the cap stack as a `cap_frame list` on `ctx` (innermost first), and resolve by linear scan. No memoization, no name mangling. The list will be short (~3 frames) in practice.
- **Push/pop with `Eio.Switch.run`**. Each `provide ... in body` opens a fresh `Eio.Switch.run` and stores the switch in the frame. Nothing at Stage 3 actually uses that switch — but Stages 8 and 11 will, so put it in the frame now rather than retrofitting. The `Eio_main.run` already running in `Driver.run_file` is the outer process switch; nest under it.
- **`StdoutLogger` must route through `ctx.sink`**, not `print_endline`. Otherwise the test harness can't capture output. The cleanest way: `DHost` takes `ctx -> value list -> value` (matches the long-term type in `plans/interpreter.md` §Runtime values), and the host body calls `Eval.emit_line ctx.sink s`. Resist the urge to make `DHost` take just `value list -> value` "to keep it simple" — you'll regret it next stage.
- **Parsing `Cap.method(args)`**. You need a `.` token. The grammar addition is small but introduces a precedence question: `expr.IDENT(args)` vs `expr.IDENT` (no parens) — at Stage 3, only the call form exists; field access lands with structs at Stage 4. Keep it that way; don't try to parse bare `.field` yet. The conflict count must stay at 1.
- **Parsing `requires {Cap1, Cap2}`**. It appears after the return-type annotation on `fn` decls (per `docs/lang/syntax.md` §6). Parse it into a list of idents, store it on `fn_decl`, and ignore it during eval. Match the syntax exactly — don't accept `requires (...)` or comma-trailing-tolerant variants beyond what the spec allows; we'll be glad later when the type checker reads from the same AST.
- **`@ Process`**: introduce an `AT` token. The scope name is just an ident (`Process`); don't try to parse `A | B` alternation yet — Stage 7. At Stage 3 every binding's scope is `Process`, and the `provide @ Scope { ... }` form from §7.3 isn't needed.
- **Constructor table** lives in a new module (e.g. `lib/host/builtin.ml`) and is registered into the program once at startup. Don't put it in `Driver` — it'll grow.

## When you hit a fork

Bias toward the simpler choice that doesn't paint you into a corner. The interpreter is for validating semantics, not performance. If you can't decide between two approaches, pick the one that touches fewer files. The Stage 2 lesson: when the parser blew up to 11 conflicts after adding `RETURN expr`, the fix was a single precedence directive, not a grammar refactor. Same playbook for any new conflicts here.

## Reporting back

When Stage 3 lands, summarize:
- What runs end-to-end (the plan's canonical example, plus whatever stress test you added).
- What surprised you in the docs/plan (lay out anything the plan or `syntax.md` got wrong or under-specified — Stage 2's report flagged a stray `;` in the plan's stress test and the missing `%nonassoc RETURN`; expect similar gotchas).
- Stage 3 is the first stage with the **real** Dilang idea (capabilities + `provide`). After this, Stage 4 introduces user-defined impls and struct types, which is where the language starts to look like itself.
