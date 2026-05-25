# Handoff: Stage 7 of the Dilang interpreter

## Where we are

Stages 1–6 are landed and green:

- `dilang-interpreter/` is a single Dune project (OCaml 5.2 + Menhir + sedlex + Eio).
- `dilang run <file.di>` evaluates a tree-walked AST and prints to stdout.
- `dune runtest` runs an `alcotest` suite (**65 tests** in 6 groups: stage1/2/3/4/5/6 expect-files, generated stress, negative-path) that diffs captured stdout against `expect/<name>.txt` or asserts on raised `Failure` substrings.
- Coverage so far: `fn main()`, `let`, int/string/bool literals, arithmetic + comparison binops, `print` intrinsic, block-as-expression, line comments **(Stage 1)**; multi-arg positional user fn calls, `return`, string interpolation `"${expr}"` with `\${` escapes and nested-string brace balancing **(Stage 2)**; `capability` declarations, `provide { Cap = impl @ Scope } in { body }`, `Cap.method(args)` dispatch, `requires {...}` on fns (parsed, not enforced), and a host stdlib registering `StdoutLogger` + `StdoutGreeter` **(Stage 3)**; user-declared `struct T { f: Ty, ... }` with brace-literal construction (DEC-009), bare-name shorthand for fieldless structs, `impl Cap1 [+ Cap2] for T` blocks with method bodies, impl-private `requires` rows (parsed only), capability `extends` (transitive closure built at resolve time), multi-binding `provide` with left-to-right cap-env capture (DEC-004), `self.field` access in user impl methods **(Stage 4)**; `if`/`else` (atom-level, brace-bodied, else-if chains), `enum E { Variant1; Variant2(payload: T) }` decls, `raise X` / `raise X(args)` raising a typed `Dilang_error`, `try expr catch { Pat -> arm; ... }` matching by variant tag with payload binders (`PWild`, `PVar`, `PVariant`), `??` (null-coalescing) and `?.field` (optional chain — single-step, `OptCall` deferred), `Option<T>` registered by host stdlib with `Some(value: T)` and `None`, `T?` type sugar carried as the literal string `"T?"`, and `raises {...}` rows on fn / impl-method / cap-method signatures (parsed and discarded) **(Stage 5)**; `defer expr` registering a **block-scoped** LIFO finalizer (DEC-012) that fires at the end of the smallest enclosing `{ ... }` on every exit path the interpreter knows about (fall-through, `return`, raised error), implemented by adding a `Scope of expr` AST node that the parser's `block:` rule wraps around every `{ }`; each `Scope` swaps a fresh `defers : (unit -> unit) list ref` onto `ctx` and uses `Fun.protect` to fire defers on exit. Activation boundaries (`call_fn`, `DUser`) only own the `Return_exn` catch — the fn body's own `Scope` is the activation's defer scope **(Stage 6)**.

Things worth knowing before you touch anything:

- **Parser** — Menhir LR + sedlex. **Three** shift/reduce conflicts, unchanged from Stage 4. All three are structurally the same — `IDENT . (LPAREN | LBRACE)` and `IDENT DOT IDENT . LPAREN` — the lookahead-into-the-follow-set ambiguity that exists because `block_item list(block_item)` allows the next statement to start with `LPAREN` or `LBRACE`. Menhir resolves all three to shift, which gives the correct semantics (Call > Var, CapCall > FieldGet, StructLit > Var). **Do not try to eliminate them.** Stage 5 nearly added a fourth (the optional `(args)` after `RAISE IDENT`) and dodged it by parsing `RAISE atom` instead and unpacking `Var` / `Call { fn = Var _; args }` in the semantic action — same trick is worth reaching for first if Stage 7 introduces another optional-payload construct. Stage 6 added `defer` and **zero** new conflicts because `DEFER expr` mirrors `RETURN expr` exactly. If you add a new shift/reduce on top of the existing three, factor with a shared-prefix-and-tail rule before resorting to precedence directives, and document why the residual conflict is harmless.
- **`expr_entry`** — a second Menhir start symbol `expr_entry: expr EOF` lets the lexer re-enter the parser to handle `${...}` sub-expressions. Reuse it if Stage 7 needs another fragment parser; don't add a third start symbol casually.
- **Block lowering** — `Ast.block_of_items` folds a `block_item list` into nested `Let { ...; body = rest }` and `Block [e; rest]`. Right-leaning. Stress tests show 500-statement blocks and 300-deep let chains run fine.
- **Sink abstraction** — output flows through `Value.sink = OutChan of out_channel | Buf of Buffer.t`. CLI uses stdout; tests use a Buffer. Host method bodies **must** call `Value.emit_line ctx.sink s`, never `print_endline`. Stage 3's stress tests fail loudly if you regress this.
- **Control-flow exceptions** — `Return_exn of value` and `Dilang_error of { tag; payload }` defined in `eval.ml`. Stage 6 did **not** add a new exception for defer — finalizers run via `Fun.protect` in the `Scope` arm. Stage 7 *will* add `Break_exn of value` (carries the optional `break v` payload — see DEC-013 below) and `Continue_exn`. The discipline: define them in `eval.ml` near `Return_exn`, catch them at the `Loop` / `While` arms only, never inside `Let`/`Block`/`Call`/`Try`. **You no longer need to defend against `Break_exn` reaching the activation boundary** — every `{ ... }` along the way is a `Scope` that wraps with `Fun.protect`, so a `break` propagating up through nested scopes naturally fires each scope's defers on the way out (correct Zig semantics). The only edge case is `break`/`continue` *outside any loop*: in that case `Break_exn` propagates past `call_fn`'s `Return_exn` catch and surfaces as an uncaught OCaml exception. Catch it at `call_fn` (and the `DUser` arm) with `failwith "break outside any loop"` *after* the `Return_exn` catch — so the fn body's own `Scope` has already fired its defers correctly by the time we reach this conversion.
- **`ctx` and `env` live in `value.ml`** — relocated at Stage 3 because `DHost` closures need to mention `ctx` and `Env.t` is `Value.env`. `lib/env.ml` is a four-line wrapper. Don't undo that. Module dep order: `Ast → Value → Env → Eval`.
- **`ctx.defers` + `Scope` AST node** (Stage 6) — head = most-recently-registered = first to fire. The parser's `block:` rule wraps every `{ ... }` in `Scope (block_of_items items)`, and the `Scope` eval arm swaps in a fresh `defers ref` and uses `Fun.protect` to fire them on exit. `Block` is the *internal* sequencing node produced by `block_of_items` and does **not** push a frame — Scope and Block are different concepts and must stay so. `run_defers` swallows per-thunk exceptions (DEC-011 / TODO breadcrumb). Stage 7 has no reason to touch the defer machinery; just remember that adding any new construct that introduces a user-visible `{ }` (none planned at Stage 7) means the parser should run it through `block` so the `Scope` wrap happens automatically.
- **Per-`provide` `Eio.Switch.run`** — Stage 3 nested `Eio.Switch.run` once per provide frame and stashed the switch on the `cap_frame`. Stage 13 (Lifecycle) is the one that finally uses the switch via `Eio.Switch.on_release`. Keep populating the field.
- **Cap resolution walks innermost-first; within a frame, reverse declaration order ("later wins")** — Stage 4 codified this. `ext_of` is built once at resolve time and includes the cap itself (reflexive closure). Match predicate: `List.mem requested_cap (Hashtbl.find ctx.ext_of bound_cap)`.
- **Constructor and variant tables** — `ctx.user_constructors` (Stage 4), `ctx.host_constructors` (Stage 3), and `ctx.variants` (Stage 5) all live on `ctx`. Lookup chains: `Var x` walks env → variants (no-payload) → user_constructors → host_constructors → fail; `Call { fn = Var name; args }` walks fns → variants (with-payload) → fail. `Call` does **not** consult constructors after DEC-009.
- **`DUser` carries an `Ast.impl_method`** — Stage 4 widened the variant. The Stage 6 dispatch arm owns only the `Return_exn` catch (`try eval ... with Return_exn v -> v`); the method body is a `Scope`, which handles defers. Stage 7's mutation work doesn't touch this — methods that mutate `self.field` will work as soon as `Assign` lands. Stage 7 should add the `Break_exn` / `Continue_exn` "outside-any-loop" failwith *after* the `Return_exn` catch here, same shape as `call_fn`.
- **`Provide.body : expr option` and `Provide.scope : ident option`** — the parser only ever emits `body = Some _, scope = None`. The §7.3 (`provide @ Scope { ... }`) and §7.4 (Wiring-value, no `in`) forms are deferred to Stage **12** / Stage **14** (post-reshuffle — see below) with breadcrumb comments. Stage 7 doesn't touch either.
- **`Using` constructor on `provide_entry`** — declared in AST, never emitted. `eval.ml` failwiths it with a Stage-14 reference. Leave it.
- **`raises` rows** — parsed by `raises_opt` and discarded at every signature position (fn, impl method, cap method). Re-raise on unmatched `try` arm is the runtime contract.
- **`T?` sugar carries as the string `"T?"`** at the type-name level. No normalization to `"Option<T>"` at the interpreter — types aren't checked at this stage.
- **`OptChain` flattens single-step** — `?.field` on `Some(impl)` returns `field` *unwrapped* if it's already an `Option`, else wraps in `Some`. §12.1: "chains do not nest Option". `?.method(args)` is **deferred** to whichever stage lands value-method dispatch.
- **Host enum registration order** — `Host_builtin.register` populates `ctx.enum_decls["Option"]` and `ctx.variants["Some"|"None"]` *before* `Driver.run_program` iterates user enum_decls. Keep this ordering if you add more host enums.
- **No semicolons in the grammar** — block items are whitespace-separated. A stray `;` in a `.di` test file fails to lex. Every `.di` written so far follows this.
- **`StructLit` field syntax**: `Foo { a: 1, b: 2 }`. Trailing comma allowed. Empty `Foo {}` allowed but bare `Foo` is the idiomatic form for fieldless structs.
- **No unary minus** — the lexer maps `-` to `MINUS` (infix binop) only. `print(-1)` is a parse error; tests have to use `0 - 1`. Whichever stage adds prefix operators owns this.
- **Named args on function calls were sketched and reverted** — DEC-010 is **Deferred**. Function calls are positional.
- **`env.values : (Ast.ident * value ref) list`** — already a ref. Stage 7 needs to add a per-binding mut flag (`Let { mut = true; ... }`) currently records it in the AST but `eval`'s `Let` arm ignores it (`mut = _`). Either widen the env entry to `(ident * value ref * bool)` or keep a parallel `mut_names` set; the plan body suggests widening. `Env.lookup` returns the value (not the ref) — you'll need a new `Env.find_ref name -> (value ref * bool) option` for `Assign` to mutate through.
- **Stage reshuffle (post-Stage-6, recorded in `plans/interpreter.md` §"Reshuffle rationale")** — the plan was reordered after Stage 6 landed. The dilang-specific machinery (scopes, Lifecycle, Wiring) is no longer next; it's been pushed to Stages **12/13/14**, gated behind a working HTTP server (Stage 11). The new order is **7 assign+loops → 8 arrays → 9 strings → 10 closures → 11 HTTP → 11.5 demo milestone → 12 scopes → 13 Lifecycle → 14 Wiring → 14.5 demo milestone → 15 concurrency → 16 cancellation → 17 streams → 18 stdin/fs → 19 tests**. Stage 6's defer machinery will be extended at Stage 16 (cancellation also fires defers) — not now.

## Source of truth

Everything below is *secondary* to:

- [`plans/interpreter.md`](./interpreter.md) — Stage 7 section starts at line 676. The reshuffle rationale is at line 77 (read it first if you're surprised by the new ordering). The canonical Stage 7 example is the `loop`/`break` + `while` mutable-counter program (lines 680–709).
- [`docs/lang/syntax.md`](../docs/lang/syntax.md) — assignment lives in §1 (mutability rules), `loop`/`while`/`break`/`continue` in §11.
- [`docs/lang/design.md`](../docs/lang/design.md) — no dedicated mutation section. The relevant rationale is §2.1 ("locals default immutable; `mut` is opt-in") and §2.10 ("optimize for review: mutation is visible at the binding site, not surprising at the use site").
- [`docs/lang/decisions.md`](../docs/lang/decisions.md) — DEC-011 (defer / error interaction, Deferred) is the only Stage-6 design entry. No DEC currently dedicated to mutability or loops. If you make a behavioral call in Stage 7 (e.g., labeled break, `Break_exn` propagating out of an activation as a runtime error vs. parse error), consider adding a DEC entry.

## What Stage 7 adds

Surface-level: mutable rebinding `x = rhs` (legal only where `x` was bound `let mut`); `loop { ... }`; `while cond { ... }`; `break` (optionally with a value) and `continue` exiting / restarting the innermost loop. **`loop` is an expression** that evaluates to the value carried by `break v` (or `VUnit` if `break;` with no value) — see DEC-013. `while` is a statement evaluating to `VUnit` (it may not execute the body, so there's no well-defined value). A `loop` with no reachable `break` has type `Never` (already a recognized type per syntax §11).

This stage finishes the surface-level mutability story that Stage 1 left half-finished (it parses `let mut` but assignment has no AST node).

The canonical example mostly tracks `plans/interpreter.md` line 680 but extends it to exercise `loop`-as-expression (`break v`) per DEC-013:

```di
fn main() {
    let mut i   = 0
    let mut sum = 0
    let total = loop {
        if i >= 10 { break sum }
        sum = sum + i
        i = i + 1
    }
    print(total)                          // 45

    let mut n = 5
    while n > 0 {
        print(n)
        n = n - 1
    }
    print("done")
}
```

Expected:
```
45
5
4
3
2
1
done
```

The plain `break` (no value) and `loop` used as a statement remain valid — `break;` yields `VUnit`, which a statement-position `loop` quietly discards.

## Cross-stage interactions worth getting right

Stage 7 interacts with Stage 6's block-scoped defer in three places. The block-scoped design makes all three Just Work — but you should add tests for them.

1. **A defer inside a loop body fires at end of each iteration.** Each iteration of `loop`/`while` re-evaluates the loop body, which is a `Scope`, which pushes a fresh defers frame. So `loop { defer release(x); ... }` releases per iteration — the natural Zig/Rust-RAII behavior, *not* the Go accumulation footgun. Test:
   ```
   fn main() {
     let mut i = 0
     while i < 3 {
       defer print("end iter ${i}")
       print("body ${i}")
       i = i + 1
     }
     print("done")
   }
   ```
   Expected output:
   ```
   body 0
   end iter 1
   body 1
   end iter 2
   body 2
   end iter 3
   done
   ```
   **Capture-semantics gotcha**: the defer body is evaluated at fire time against the live env, not at registration time. `i` was already incremented before the defer fires (the `i = i + 1` runs *inside* the iteration's scope, then end-of-scope runs defers). So "end iter 1" appears after "body 0". This is the right behavior under DEC-012 + the fire-time-evaluation rule, but it surprises readers used to Go. If a test wants per-iteration capture, bind `i` to an immutable local first (`let snapshot = i; defer print("...${snapshot}")`).

2. **`break`/`continue` correctly fire the defers of every scope they exit.** `Break_exn` raised inside a `loop` propagates up; each enclosing `Scope`'s `Fun.protect` runs that scope's defers on the way; the `Loop` arm catches the exception. So `loop { defer X; ... break ... }` runs `X` before the loop exits. No special handling needed — the Stage 6 machinery does it. Add a test:
   ```
   fn main() {
     let mut i = 0
     loop {
       defer print("iter defer ${i}")
       if i >= 2 { break }
       i = i + 1
     }
     print("after loop")
   }
   ```
   Expected:
   ```
   iter defer 1
   iter defer 2
   iter defer 3
   after loop
   ```
   The defer registered on the iteration that breaks still fires (it's in the iteration's scope, which is exiting). Same gotcha re: `i` value at fire time.

3. **`try` is its own defer scope, distinct from the loop body.** Block-scoped means `try { defer X; break }` runs `X` as the try-body exits via `break`, *then* the `break` propagates to the enclosing loop. Add a test:
   ```
   fn main() {
     loop {
       try {
         defer print("try cleanup")
         break
       } catch { _ -> print("never") }
     }
     print("out")
   }
   ```
   Expected:
   ```
   try cleanup
   out
   ```
   `try` does **not** catch `Break_exn` — only `Dilang_error`. So `break` propagates past `catch`, but `Fun.protect` on the try-body scope still runs its defer first. Pin this with a test.

4. **`return` inside a loop fires every enclosing scope's defers on its way out.** Already works (Stage 6 covered it for `if`-branch return); add a `loop`-version test combining `defer` at fn-body level, `defer` inside the loop body, and `return` from inside the loop. Order: inner-loop defer → fn-body defer → caller resumes.

## Stage 7 deliverable

Cut a single commit / PR that:

1. Adds `test/stages/07_assign_loops.di` — the canonical example above (including `let total = loop { ... break sum }`). Expect file matches.
2. Adds `test/stages/07b_while.di` — `while` with a mutable counter; verifies condition re-evaluation; uses `while` in statement position (it has no value).
3. Adds `test/stages/07c_continue.di` — `continue` skipping the rest of an iteration; in `while`, the next condition eval still runs; in `loop`, the body re-enters immediately.
4. Adds `test/stages/07d_defer_per_iteration.di` — defer inside a `while`/`loop` body fires at end of each iteration (DEC-012 / cross-stage §1). Use an iteration-independent body (e.g., `defer print("end iter ${i}")` after noting the capture-semantics gotcha in a comment).
5. Adds `test/stages/07e_break_fires_defers.di` — defer in a loop iteration that breaks still fires (cross-stage §2).
6. Adds `test/stages/07f_break_in_try_runs_try_defers.di` — `break` inside `try { defer X; break }` runs `X` then breaks out of the loop; `catch` is bypassed (cross-stage §3).
7. Adds `test/stages/07g_return_through_loop.di` — `return` from inside a loop fires every enclosing scope's defers on the way out (cross-stage §4): inner-loop scope defer → fn-body scope defer → caller resumes.
8. Adds `test/stages/07h_loop_as_expression.di` — `let r = loop { ... break v }`; `loop` with no break in `-> Never` position is *not* tested here (no syntax for it in surface code without arrays/closures — skip). Verify `break;` (no value) yields `VUnit` when the `loop` is used as a statement.
9. Adds `test/stages/07i_mutate_self_field.di` — an `impl` method that mutates `self.field` via `self.field = rhs`. Confirms `AssignField` parses and that impl-fields-as-refs (Stage 4) mutate in place.
10. Extends `test/run_test.ml` with a `stage7` group registering 1–9, plus at least four new entries to `stress`:
    - 10,000-iteration `while` counter loop; print final `i`.
    - 50 nested `loop { ... break }` blocks each in their own fn; verify total print count.
    - 100-iteration `loop` registering one defer per iteration (body iteration-independent); verify exactly 100 lines fired in the expected per-iteration interleaving.
    - `loop`-as-expression returning a string built across iterations (mutable accumulator + `break acc`); pin output.
11. Adds to the `errors` group:
    - `let x = 1; x = 2` — assignment to immutable binding (`cannot assign to immutable \`x\``).
    - `nope = 1` at the top of `main` — assignment to unbound name (`unknown name`).
    - `break` outside any loop — currently a runtime error (`break outside any loop`); pin the message. (Parse-time rejection is a fork; see below.)
    - `continue` outside any loop — same shape.
    - `while 1 { ... }` — non-Bool condition.
12. Passes `dune build && dune runtest` with shift/reduce conflict count **≤ 3**. Two new constructs to watch:
    - `IDENT EQ expr` as a block_item — the same EQ that appears in `let` bindings. Menhir should disambiguate cleanly because EQ doesn't appear inside `expr`; see "Implementation hints".
    - `BREAK expr` (optional payload, per DEC-013) — use the same trick Stage 5 used for `raise atom`: parse `BREAK atom?` and unpack in the semantic action. **Don't** introduce an optional production directly; that's the conflict path Stage 5 explicitly dodged.

## Out of scope at this stage

- **Labeled break** (`break 'outer`) — Stage 7's `Break_exn` is one-deep. Adding labels requires either nested exception types or a label-stack on `ctx`; defer.
- **`loop` returning a value from a `while`** — by DEC-013 only `loop` is an expression; `while`/`for` always evaluate to `VUnit`.
- **`for x in xs`** — needs arrays. Stage 8.
- **`do { ... } while`-style post-test loops** — not in the language.
- **Compound assignment** (`+=`, `-=`, etc.) — not in v0. Could add at Stage 7 with one parser arm per op, but the plan body doesn't list it. Skip.
- **Field reassignment via `self.f = rhs` in non-impl-method contexts** — `self` only exists inside impl methods; allowing arbitrary `expr.field = rhs` would need the parser to admit assignment LHSes beyond bare IDENTs. Defer that to whichever stage motivates it.
- **`scope X` decls, `@ X` non-Process annotations, `provide @ Scope { ... }`** — Stage 12 (post-reshuffle).
- **`Lifecycle` impls, `start`/`shutdown`, `ExitReason`** — Stage 13.
- **`Wiring` values / `using`** — Stage 14.
- **Closures, lambdas, generic row variables** — Stage 10.
- **HTTP** — Stage 11 (and the demo backbone from there onwards).
- **Static enforcement of `raises` rows** — type-checker phase.
- **Defer-raises-inside-defer beyond v0 swallow** — DEC-011, parked.

## Implementation hints

Things that are easy to get subtly wrong:

- **AST additions**:
  ```ocaml
  type expr =
    | ...
    | Assign      of { name : ident; rhs : expr }
    | AssignField of { recv : expr; name : ident; rhs : expr }
    | Loop        of expr
    | While       of { cond : expr; body : expr }
    | Break       of expr option              (* DEC-013: `break v` carries a value *)
    | Continue
  ```
  `Break` carries `expr option` per DEC-013 (`break;` → None → `VUnit`; `break v` → Some v). `Continue` stays nullary (no carried value). `AssignField` is separate from `Assign` so the parser can distinguish `IDENT = rhs` from `IDENT DOT IDENT = rhs` at the block_item level without overloading.

- **Parser**:
  - Four new keywords: `loop → LOOP`, `while → WHILE`, `break → BREAK`, `continue → CONTINUE`.
  - `loop` lives at `atom` level (it's an expression per DEC-013, like `if`). `while` lives at block_item level (statement-only). Assignment and break/continue live at block_item level for the LHS forms; `break` can also be an expression-position form for `break v` inside a larger expression, though the common case is a statement.
    ```
    atom:
      | LOOP; b = block                                  { Loop b }
      | ...                                              (* existing if/try/provide/etc. *)

    block_item:
      | LET ...                                          (* existing *)
      | n = IDENT; EQ; e = expr                          { BExpr (Assign { name = n; rhs = e }) }
      | recv = IDENT; DOT; f = IDENT; EQ; e = expr       { BExpr (AssignField { recv = Var recv; name = f; rhs = e }) }
      | WHILE; c = expr; b = block                       { BExpr (While { cond = c; body = b }) }
      | BREAK; p = break_payload_opt                     { BExpr (Break p) }
      | CONTINUE                                         { BExpr Continue }
      | e = expr                                         { BExpr e }

    break_payload_opt:
      |                                                  { None }
      | a = atom                                         { Some a }
    ```
  - **Conflict watch (`IDENT EQ expr`)**: the EQ that appears in `let` bindings is the same token. Menhir, after consuming a single `IDENT` at block_item start, peeks one token: if `EQ`, take the Assign arm; otherwise fall through to `expr`. Since `EQ` never appears inside `expr`, Menhir should disambiguate cleanly with zero new conflicts. If it doesn't, factor with a `block_item_starting_with_ident` shared-prefix rule — the technique Stage 5 used for `raise`. Don't reach for `%prec`.
  - **Conflict watch (`BREAK atom?`)**: same shape Stage 5 used for `raise atom`. Don't model the payload as a Menhir option/optional — parse `BREAK; p = break_payload_opt` where `break_payload_opt` is an explicit rule (None | Some atom). That keeps the optional-prefix problem (which Stage 5 nearly added a fourth conflict for) factored cleanly. If Menhir still flags, fall back to: parse `BREAK atom` and `BREAK` as two arms and accept the slight code duplication.
  - **Conflict watch (`IDENT DOT IDENT EQ`)**: this is the `AssignField` arm. Already an existing conflict point — `IDENT DOT IDENT . LPAREN` is one of the three known shift/reduce. Adding `EQ` as a peek-after disambiguator should be fine because EQ isn't in any expr alternative; same reasoning as `IDENT EQ`.

- **Env extension** — `env.values : (ident * value ref) list`. Two options:
  1. Widen to `(ident * value ref * bool)` (mut flag co-located). Touches `Env.extend` and every callsite (there are ~5).
  2. Maintain a parallel `mut_names : ident list` (or use a Set). Less invasive but two structures to keep in sync.
  Recommendation: **option 1**. The Env API is tiny (`empty`, `extend`, `lookup`); widening is a one-pass change and keeps everything addressed by name.

  Add `Env.find_ref : t -> ident -> (value ref * bool) option`. `Assign`'s eval arm uses it to mutate; the existing `Env.lookup` stays for read-only `Var` paths.

- **Eval**:
  ```ocaml
  exception Break_exn of value             (* DEC-013: carries break payload *)
  exception Continue_exn

  | Assign { name; rhs } ->
      (match Env.find_ref ctx.env name with
       | Some (r, true)  -> r := eval ctx rhs; VUnit
       | Some (_, false) -> failwith ("cannot assign to immutable `" ^ name ^ "`")
       | None            -> failwith ("unknown name `" ^ name ^ "`"))

  | AssignField { recv; name; rhs } ->
      (match eval ctx recv with
       | VImpl iv ->
           (match List.assoc_opt name iv.fields with
            | Some r -> r := eval ctx rhs; VUnit
            | None   -> failwith ("no field " ^ name ^ " on " ^ iv.ty))
       | _ -> type_err ("field assignment on non-impl value: " ^ name))

  | Loop body ->
      (try while true do ignore (eval ctx body) done; assert false
       with Break_exn v -> v)

  | While { cond; body } ->
      (try
         while (match eval ctx cond with
                | VBool b -> b
                | _ -> type_err "while condition not Bool") do
           try ignore (eval ctx body) with Continue_exn -> ()
         done
       with Break_exn _ -> ());
      VUnit

  | Break payload_opt ->
      let v = match payload_opt with
        | Some e -> eval ctx e
        | None   -> VUnit
      in
      raise (Break_exn v)

  | Continue -> raise Continue_exn
  ```

  Notes:
  - `Loop` returns the `Break_exn` payload (DEC-013). The `assert false` after the infinite loop satisfies OCaml's type-checker — the only way out of the `while true` is `Break_exn`.
  - `While` ignores the carried value (`Break_exn _ -> ()`) and always returns `VUnit`. A `break v` inside a `while` body is accepted by the parser but the value is discarded; that's the right behavior (matches Rust). Adding a separate `BreakValue` AST node to reject it at parse time is overkill for Stage 7.
  - `Continue_exn` is caught *inside* the `while` body's iteration loop, so the next condition eval still runs. `Break_exn` is caught *outside* the whole `while`/`loop`. Same asymmetry as Rust.
  - The defer machinery doesn't appear in this eval. That's the whole point of DEC-012: every `{ ... }` is a `Scope`; `Break_exn` propagating up through scopes fires their defers naturally via the Stage 6 `Fun.protect`. Stage 7 doesn't write any defer code.

- **Activation boundary — `break`/`continue` outside any loop.** A leaked `Break_exn` or `Continue_exn` would otherwise surface as a wild OCaml exception. Catch them at `call_fn` and the `DUser` arm, *after* the `Return_exn` catch, converting to `failwith`. The fn-body's own `Scope` has already fired its defers by the time we reach this conversion, so the discipline is just "give it a good error message":
  ```ocaml
  try eval ctx' f.body with
  | Return_exn v -> v
  | Break_exn _  -> failwith "break outside any loop"
  | Continue_exn -> failwith "continue outside any loop"
  ```
  Stage 7 fork: parse-time rejection is stricter (Rust does it), but requires tracking loop-depth in the parser or a post-parse walker. Runtime detection here is fine for now with a TODO for a later validation pass.

## When you hit a fork

Same playbook as before. Bias toward the simpler choice that doesn't paint you into a corner.

Stage 7's most likely forks (most pre-settled by DEC entries):

1. **`break`/`continue` outside any loop — parse-time or runtime error?** Recommendation: **runtime** via the `call_fn`/`DUser` catch. Parse-time requires loop-depth tracking, which is scope creep. Leave a TODO breadcrumb.

2. **Widen `env.values` vs parallel `mut_names`.** Recommendation: **widen** `env.values` to `(ident * value ref * bool)`. Tiny API; one-pass change.

3. **Reject `break v` inside `while`?** The eval sketch above accepts it and discards the value (matching Rust). A parse-time rejection would need a `while_body` rule distinct from `loop_body`. Recommendation: **accept and discard** at Stage 7; a stricter check can land later.

4. **Compound assignment (`+=`, etc.)** Recommendation: **skip**. Mechanical and not on the plan.

5. **(Pre-settled by DEC-013)** `loop` is an expression yielding `break v`'s payload; `while`/`for` are statements. Implement, don't redebate.

6. **(Pre-settled by DEC-012)** Defer is block-scoped; each `{ ... }` is its own frame. Stage 7 inherits this — no defer code to write, just tests that exercise the cross-stage interactions.

## Reporting back

When Stage 7 lands, summarize:

- What runs end-to-end: the canonical example with `let total = loop { ... break sum }`, plus the cross-stage interactions (defer fires per iteration; `break` runs the iteration's defers on its way out; `try { defer X; break }` runs `X` and then escapes the catch; `return` fires every enclosing scope's defers).
- What surprised you. Likely candidates:
  - (a) Did `IDENT EQ expr`, `IDENT DOT IDENT EQ expr`, and `BREAK atom?` introduce any new shift/reduce conflicts? Expectation: zero.
  - (b) Whether the env widening turned out trivial or gnarly (Env.lookup/extend callsites — should be ~5).
  - (c) Whether the capture-semantics gotcha (defer body evaluated against live env, not registration env) showed up unexpectedly anywhere besides the iteration tests.
  - (d) Whether `Loop` returning the `Break_exn` payload composes cleanly with `let total = loop { ... break sum }` in `let` position. (The `Scope` around the `loop` body must let `Break_exn` propagate out of the inner scope; only the `Loop` arm catches it.)
  - (e) Any DEC-011 fallout: does a `break` inside a defer body do the right thing? (It shouldn't — the defer body's scope is not the loop's scope, so `Break_exn` from a defer would leak past the loop's catch. Likely needs a Stage-7 test that pins "break inside defer body is a runtime error" or similar.)
- One-liner: Stage 7 gives Dilang **mutable state and expression-shaped iteration** — `let mut x = ...` + `x = rhs`, `self.field = rhs`, `let total = loop { ... break v }`, `while`/`continue`. Block-scoped defer (DEC-012) means iteration cleanup composes naturally with `break`/`continue`/`return`/`raise` without Stage 7 writing any defer code. Stage 8 adds arrays and `for x in xs` on top.
