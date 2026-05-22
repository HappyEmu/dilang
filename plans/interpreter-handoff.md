# Handoff: Stage 2 of the Dilang interpreter

## Where we are

Stage 1 is landed and green:

- `dilang-interpreter/` is a single Dune project (OCaml 5.2 + Menhir + sedlex + Eio).
- `dilang run <file.di>` evaluates a tree-walked AST and prints to stdout.
- `dune runtest` runs an `alcotest` suite that diffs captured stdout against `expect/<name>.txt`.
- Stage 1 covers: `fn main()`, `let` (incl. `mut`, declared only — reassignment is Stage 13), int / string / bool literals, all arithmetic + comparison binops, `print` intrinsic, block-as-expression, shadowing, line comments. Test files: `test/stages/01_arith.di` (canonical plan example) and `test/stages/01b_full.di` (stress test).

Notes from Stage 1 worth knowing before touching anything:

- **Parser**: Menhir LR + sedlex. One shift/reduce conflict in `expr`/`atom` that menhir resolves by shifting — harmless. If you add productions, run `dune build` and confirm the count doesn't grow silently.
- **Block lowering**: the parser builds an internal `block_item` list and folds it into nested `Let { ...; body = rest }` and `Block [e; rest]` via `Ast.block_of_items`. This matches the AST shape in `plans/interpreter.md` but is right-leaning — eval recurses block-depth deep. Survives 500k-stmt programs on default macOS stack, no need to refactor.
- **Sink abstraction**: `print` writes through `Eval.sink = OutChan of out_channel | Buf of Buffer.t`. The CLI uses stdout; tests use a Buffer for deterministic capture. Keep this — it'll matter again at Stage 14.
- **Eio is wired but unused**: `Driver.run_file` opens `Eio_main.run` + `Eio.Switch.run` before parsing. Nothing depends on it yet, but Stage 3 will start pushing frames onto a switch, so don't unwire it.
- **Top-level fns aren't closures**: `Eval.call_fn` builds a fresh `Env.empty` per activation. Top-level fn lookup is via `ctx.fns : (ident, fn_decl) Hashtbl.t`. Closures arrive at Stage 10.

## Source of truth

Everything below is *secondary* to:

- [`plans/interpreter.md`](./interpreter.md) — Stage 2 section starts around line 149. Read it before writing code.
- [`docs/lang/design.md`](../docs/lang/design.md), [`docs/lang/syntax.md`](../docs/lang/syntax.md), [`docs/lang/decisions.md`](../docs/lang/decisions.md) — language reference. If something's ambiguous, check `decisions.md` first. If it's still ambiguous, ask — don't invent semantics.

## What Stage 2 adds

From `plans/interpreter.md`:

- **Multi-argument function calls.** Stage 1 only handled `print` as a special case and top-level fns with 0 args (`main`). Stage 2 makes `Call { fn = Var f; args }` general: look up `f` in the fn table, bind params, eval body, propagate return.
- **Return values.** `Return e` raises a sentinel exception caught at the activation boundary so the value escapes nested blocks. Implicit last-expression return already works via block-as-expression — add the explicit `return` keyword too. The AST node `Return of expr` already exists in the plan.
- **String interpolation `"${expr}"`.** Lex strings into a list of literal chunks and embedded expressions. AST: `StringInterp of string_part list` where `string_part = SLit of string | SInterp of expr`. Eval concatenates using `Value.to_display`.

## Stage 2 deliverable

Cut a single commit / PR that:

1. Adds `test/stages/02_functions.di` (the plan's example: `greet`, `area`, `main`) and `test/expect/02_functions.txt` (`hello, world` / `12`).
2. Optionally adds a `02b_*.di` stress test exercising nested calls, recursion-free chains, several interpolations per string, escapes inside interpolated strings.
3. Updates `test/run_test.ml` to include the new stage.
4. Passes `dune build && dune runtest`.

Don't add anything Stage 3 owns — no capabilities, no `provide`, no `requires`/`raises` enforcement. The plan parses-and-ignores `requires`/`raises` rows starting at Stage 3, so for now the parser still doesn't need them at all.

## Out of scope at this stage

- Closures and lambdas (`|x| ...`) — Stage 10.
- Generics syntax `<R, E>` — Stage 10.
- Capabilities, `provide`, `CapCall` — Stage 3.
- Static row checks of any kind — never, in the interpreter. Type checker is a separate phase.
- `if`/`else`, `try`, `raise`, `Option` — Stage 5.

## Implementation hints

Things that are easy to get subtly wrong:

- **Lexer state for interpolation.** Sedlex's `lex_string` in `lib/lexer.ml` currently swallows the whole `"..."` and emits a single `STR` token. For interpolation you'll either (a) emit a sequence of tokens (`STR_START`, `STR_CHUNK`, `INTERP_LBRACE`, expr tokens, `INTERP_RBRACE`, `STR_CHUNK`, `STR_END`) and reassemble in the parser, or (b) lex the literal eagerly into a `string_part list` value and emit a single `STR_INTERP` token carrying the parsed structure. Option (b) is simpler and matches the AST 1:1 — recommend.
- **Return semantics.** Add `exception Return_exn of value`. `eval` raises it in the `Return` case; `call_fn` catches at the activation boundary with `try ... with Return_exn v -> v`. Don't catch it in `Block` or `Let` — it must escape.
- **Display in interpolation.** `Value.to_display` is what `print` already uses. Reuse it. `VBool true` renders as `true`, `VInt 12` as `12`, `VStr "x"` as `x` (no quotes — interp puts the raw chars into the surrounding string).
- **Top-level fn arity check** is already in `Eval.call_fn` — keep it; helps catch typos in test programs.

## When you hit a fork

Bias toward the simpler choice that doesn't paint you into a corner. The interpreter is for validating semantics, not performance. If you can't decide between two approaches, pick the one that touches fewer files.

## Reporting back

When Stage 2 lands, summarize: what runs, what doesn't, what surprised you (docs, plan, anything in the language), anything in the plan that turned out wrong. Then we pick up Stage 3 — the first stage with the real Dilang idea (capabilities + `provide`).
