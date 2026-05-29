# Dilang interpreter — incremental plan

A tree-walking interpreter in OCaml 5 + Eio that grows one concept at a time. Each stage has a small `.di` program demonstrating only the constructs added at that stage. The interpreter must run that program at the end of the stage.

References: design §§1–6, syntax §§1–17, DEC-001..022, RFC-001 (`with` scoped wiring), examples/01-layered-backend, playground/01..09.

> **Status (2026-05):** Stages 1–11 and Milestone 11.5 are implemented and green
> (`dune build && dune runtest` from `dilang-interpreter/`, **138 tests**). Stages
> 12–19 and the type-checker phase are not yet built; Stage 12 is the active next
> stage. Surface syntax in this plan follows **RFC-001** (`with [ Cap <- impl ] @
> 'Scope { body }`, apostrophe-prefixed lifetimes); the older `provide … in …`
> shown in earlier drafts is gone from the grammar. For shipped stages the
> authoritative reference is the code and `docs/lang/{syntax,decisions}.md`.

-----

## 0. Why this shape

Dilang has two hard semantic moves: capability rows resolved through lexical `with` blocks (RFC-001; formerly `provide`), and suspension without function coloring via the `IO` capability. Tree-walking sidesteps the type-checker problem (defer to a later phase) and Eio's effect-handler scheduler maps the suspension story almost 1:1:

| Dilang construct                         | OCaml/Eio mechanism                                         |
|------------------------------------------|-------------------------------------------------------------|
| Capability stack lookup                  | `cap_env` = list of `cap_frame` walked outside-in           |
| `with [ ... ] @ 'Scope { body }`         | Open `Eio.Switch.t`, push frame, run `start`s, eval body    |
| `Lifecycle.shutdown` in reverse order    | `Eio.Switch.on_release` (LIFO) per started impl             |
| `with_cancel`, `tok.trip()`              | Switch's cancel context; `Eio.Cancel.cancel`                |
| `uncancellable { ... }`                  | `Eio.Cancel.protect`                                        |
| `IO.spawn(f)` / `Future<R, E>`           | `Eio.Fiber.fork_promise ~sw`                                |
| `Group<R, E>`                            | A long-lived `Switch` + `Fiber.fork`s into it               |
| `stream { ... yield x ... }`             | Producer fiber + 0-capacity `Eio.Stream`                    |
| `defer X`                                | Per-activation finalizer list; `Fun.protect` on every exit  |
| `Drop`                                   | Per-value finalizer hook, run when scope ends or rebound    |
| Test runtime (§2.3.3)                    | `Eio_mock.Backend` + `Eio_mock.Clock`                       |

The interpreter does not invent its own effects. Capability calls into `IO` ultimately invoke OCaml code that calls Eio; suspension is Eio's, not ours.

**Static row checking is out of scope for the interpreter itself.** Rows are parsed and stored on the AST, but not validated. The type checker is a separate phase that consumes the same AST.

-----

## 1. How this plan grows

Each stage:

1. **Example** — a small `.di` program that the interpreter must run at the end of the stage. The program demonstrates only the constructs introduced in that stage (plus everything from previous stages).
2. **What's new** — the language constructs introduced.
3. **Interpreter changes** — AST additions, eval rules, host stdlib additions.
4. **What's deferred** — features intentionally not yet handled.

Stages are ordered so each one depends only on prior stages. Two design rules:

- A construct is introduced in the earliest stage where it can be demonstrated on its own. Errors, for example, don't require capabilities, so they appear before the more complex capability features.
- Capabilities and impls are introduced in three stages (host-only → user impls → `requires` row plumbing) because that staircase is genuinely useful: the first stage proves capability *dispatch*, the second proves *binding*, the third proves *composition*.

Host stdlib work scales with stages: each stage names the host types it requires (`StdoutLogger`, `FiberRuntime`, etc.) and the host implementation lives next to it.

The stage list:

| # | Title                                | New language constructs                                              |
|---|--------------------------------------|----------------------------------------------------------------------|
| 1 | Arithmetic and bindings              | `fn`, `let`, literals, ops, `print` intrinsic                        |
| 2 | Functions and interpolation          | params, return values, `"${x}"`                                      |
| 3 | First capability                     | `capability`, `with [ Cap <- impl ] @ 'Process { … }`, `Cap.method`  |
| 4 | User impls and composition           | `struct`, `impl X for T`, inherent `impl T {…}` (DEC-022), impl-private `requires`, `extends`, multi-binding `with`, value-method dispatch (DEC-020) |
| 5 | Errors and Option                    | `enum`, `raise`, `try ... catch`, `Never`, `T?`, `??`, `?.`          |
| 6 | Defer                                | `defer`                                                              |
| 7 | Assignment and loops                 | `x = rhs`, `loop`, `while`, `break`, `continue`                      |
| 8 | Arrays and iteration                 | `[a, b, c]`, `xs[i]`, `.len`/`.push`, `for x in xs`                  |
| 9 | Strings                              | `.len`, `.split`, `.contains`, `.starts_with`, `.ends_with`, `.trim` |
| 10 | Closures                            | `\|x\| body`, function-type values, capability capture              |
| 11 | HTTP server and client               | `HttpServer`, `HttpClient`, `Request`, `Response`, `HttpError`      |
| — | **Milestone 11.5** — HTTP service with router | no new features; first ship-worthy program                |
| 12 | Scopes                              | `scope 'X under 'Parent`, `@ 'X` on caps and bindings, `with […] @ 'X` |
| 13 | Lifecycle                           | `Lifecycle` impls, `start`/`shutdown`, `ExitReason`, topo order      |
| 14 | Wiring values                       | `with [ … ]` w/o body → `Wiring`, `...spread`, lexical override      |
| — | **Milestone 14.5** — service with `@ 'Request`, DB pool, dev/test/prod wirings | no new features        |
| 15 | Concurrency via IO                  | `IO.spawn`, `Future`, `Group`, `Mutex`; concurrent HTTP impl         |
| 16 | Cancellation                        | `with_cancel`, `Cancelled`, `uncancellable`, `with_timeout`, `select` |
| 17 | Streams                             | `stream { yield }`, `for x in stream`                                |
| 18 | Stdin and filesystem capabilities   | `StdinReader`, `FsRead`, `FsWrite`                                   |
| 19 | Tests as a top-level form           | `test "..." { ... }`, `assert`, mock backend                         |

Plus two non-stage future items:
- **The static type checker** — consumes the AST and enforces what the interpreter currently trusts (rows, scope-escape, exhaustiveness).
- **The trait system** — *design not yet settled.* A named interface resolved by receiver value (as opposed to `capability`, which resolves through `with` blocks). The runtime mechanism it would reuse already exists — value-method dispatch (DEC-020) — but the surface design is open (see Open Questions). syntax.md §3 sketches a candidate shape (`trait`, `extends`, `Self`, default bodies), and the AST reserves a `DTrait` node, but **no `trait` keyword, parser rule, or eval path is implemented** — only `capability` exists as an interface decl. Not scheduled as a numbered stage until the design lands.

### Reshuffle rationale (post-Stage-6)

The original ordering finished the dilang-specific machinery (scopes, Lifecycle, Wiring, closures, concurrency, cancellation) before the boring features that let you write real programs (loops, arrays, strings, network I/O). After Stage 5 landed, that left an awkward gap: the language could express scoped transactions on paper but couldn't run `wc`.

The reshuffle frontloads **assignment + loops (7)**, **arrays (8)**, and **strings (9)** so closures (10) and the first network capability (11) arrive on top of a usable substrate. Stage 11 is the inflection point — once `HttpServer` runs, every subsequent stage motivates itself by improving the same demo service: routed → scoped → pooled → concurrent → cancellable → streamed → tested.

Two milestones (11.5 and 14.5) ship complete programs with no new language features, to validate the design against running code before the next round of machinery lands.

### Demo backbone

Stages 11 through 19 all sharpen the same artefact: a backend HTTP service. The progression:

| After stage | What the service does |
|-------------|-----------------------|
| 11 | Responds to `curl`; single connection at a time; stateless handler |
| 11.5 (milestone) | Route table, query parsing, JSON-shaped responses |
| 12 (scopes) | `@ 'Request` bindings around each handler (`RequestId`, scoped logger) |
| 13 (Lifecycle) | DB connection pool with `start`/`shutdown` |
| 14 (Wiring) | `dev_runtime()` / `prod_runtime()` / `test_runtime()` selected at `main` |
| 14.5 (milestone) | Complete service with all of the above, manually exercised |
| 15 (concurrency) | Concurrent request handling (drop in `EioHttpServer`) |
| 16 (cancellation) | Per-request timeouts, graceful shutdown |
| 17 (streams) | Chunked responses, server-sent events |
| 18 (stdin/fs) | Config files, log file output |
| 19 (tests) | `test "..." = with [ ... ] { ... }`, mock HTTP client |

Each stage's example program is a small delta on the previous one, not a fresh toy.

-----

## Stage 1 — Arithmetic and bindings  ✅ *implemented*

### Example

```di
fn main() {
    let x = 1 + 2
    let y = x * 10
    print(y)
    print("done")
}
```

Expected stdout:
```
30
done
```

### What's new

`fn main()`, `let x = ...`, `let mut x = ...`, integer + string literals, basic operators (`+`, `-`, `*`, `/`, `==`, `<`, …), built-in `print(value)`.

`print` is an interpreter intrinsic, not a capability. It exists so we can observe behaviour before capabilities are introduced. The host stdlib defines exactly one free function: `print : value -> unit` writing to stdout. After Stage 3, real programs route through `Logger` and `print` becomes a debug crutch.

### Interpreter changes

Parser: produce AST for `fn` decls, `let` (mut or not), expression statements, literals, binary ops, calls to a free name.

AST core:

```ocaml
type expr =
  | Lit       of literal
  | Var       of ident
  | Let       of { name : ident; mut : bool; rhs : expr; body : expr }
  | Block     of expr list
  | Call      of { fn : expr; args : expr list }    (* `f(args)` *)
  | BinOp     of bin_op * expr * expr

and literal = LInt of int64 | LStr of string | LBool of bool | LUnit

type decl = DFn of { name : ident; params : (ident * ty) list; body : expr; ... }
```

Eval skeleton (final shape — many cases added in later stages):

```ocaml
type value = VInt of int64 | VStr of string | VBool of bool | VUnit | ...

type env = { values : (ident * value ref) list; (* ... *) }

let rec eval (ctx : ctx) : expr -> value = function
  | Lit (LInt n) -> VInt n
  | Lit (LStr s) -> VStr s
  | Var x -> !(List.assoc x ctx.env.values)
  | Let { name; rhs; body; _ } ->
      let r = ref (eval ctx rhs) in
      eval { ctx with env = { ctx.env with values = (name, r) :: ctx.env.values } } body
  | Block es -> List.fold_left (fun _ e -> eval ctx e) VUnit es
  | Call { fn = Var "print"; args = [a] } ->
      print_value (eval ctx a); VUnit
  | BinOp (Add, a, b) ->
      (match eval ctx a, eval ctx b with VInt x, VInt y -> VInt Int64.(add x y) | _ -> panic)
  | _ -> assert false
```

Eio is wired but barely used: `Eio_main.run` opens the top-level switch, hands `ctx` to `eval`.

Host stdlib at this stage: `print` only.

### Deferred

Everything else.

-----

## Stage 2 — Functions and interpolation  ✅ *implemented*

### Example

```di
fn greet(name: Str) {
    print("hello, ${name}")
}

fn area(w: I64, h: I64) -> I64 {
    w * h
}

fn main() {
    greet("world")
    print(area(3, 4))
}
```

Expected:
```
hello, world
12
```

### What's new

Multi-argument function calls, return values, string interpolation `"${expr}"`. (Function-call dispatch existed in Stage 1 only as `print` special case; here it becomes general.)

### Interpreter changes

AST additions:

```ocaml
type expr =
  | ...
  | StringInterp of string_part list
  | Return of expr        (* not yet used in examples, but cheap to add *)

and string_part = SLit of string | SInterp of expr
```

Eval additions:

- Resolve top-level function names: build a `prog.fns : (ident, fn_decl) Hashtbl.t` at startup.
- `Call { fn = Var f; args }` looks up `f`, binds parameter values, evaluates body in a fresh activation. Wrap in `try ... with Return_exn v -> v`.
- StringInterp: evaluate parts; concatenate via `Display` (for now: hand-roll string-of for `VInt`, `VStr`).

```ocaml
exception Return_exn of value

let call_fn ctx f args =
  let activation = {
    ctx with
    env = { ctx.env with
            values = List.combine (List.map fst f.params) (List.map ref args) }
  } in
  try eval activation f.body with Return_exn v -> v
```

### Deferred

Closures (Stage 10), generic functions, `requires`/`raises` (parsed and ignored).

-----

## Stage 3 — First capability  ✅ *implemented*

### Example

```di
capability Logger {
    fn info(msg: Str)
}

fn greet(name: Str) requires {Logger} {
    Logger.info("hello, ${name}")
}

fn main() {
    with [
        Logger <- StdoutLogger
    ] @ 'Process {
        greet("world")
    }
}
```

Expected: `hello, world`.

### What's new

`capability X { fn m(...) }` declarations, `with [ Cap <- impl ] @ 'Scope { body }` (RFC-001), `Cap.method(args)` dispatch syntax, the `'Process` lifetime. `requires {Logger}` is parsed but not enforced at runtime; lookup will fail if it's missing at the call site, with a clearer message than name-resolution would give.

(`StdoutLogger` is written bare because it is a fieldless struct — DEC-009: fieldless structs construct as `Foo`, structs with fields as `Foo { … }`; `()` is only ever a call. This is independent of whether the impl is host- or user-defined.)

This is the first **real** Dilang program. After this stage the interpreter has the language's core idea working.

### Interpreter changes

AST additions:

```ocaml
type expr =
  | ...
  | CapCall of { cap : ident; method_ : ident; args : expr list }
  (* RFC-001: the implemented node is `WithCaps` (formerly `Provide`). *)
  | WithCaps of { entries : with_entry list; scope : lifetime option;
                  body : expr option }

and with_entry =
  | Binding of { cap : ident; rhs : expr; scope : lifetime option }   (* Cap <- rhs [@ 'Scope] *)
  | Spread  of expr                                                   (* ...wiring_expr *)

type decl = ... | DCap of cap_decl

and cap_decl = { name : ident; methods : cap_method list; ... }
```

Name-resolution pass: walk every body, rewrite `Call { fn = Var x; ... }` to `CapCall { cap = x; ... }` when `x` names a declared `capability`. (Bare `Cap.method` syntax is parsed as such directly — see syntax §2.1.)

Env addition:

```ocaml
type cap_frame = {
  scope    : ident;                    (* "'Process" *)
  bindings : (ident * impl_value) list;
  switch   : Eio.Switch.t;             (* this frame's switch; mostly for later stages *)
}

type env = { values : ...; caps : cap_frame list }
```

Eval:

```ocaml
| WithCaps { entries; scope; body = Some b } ->
    Eio.Switch.run @@ fun sw ->
      let scope_name = Option.value scope ~default:"'Process" in
      let bindings = List.map (eval_entry ctx) entries in
      let frame = { scope = scope_name; bindings; switch = sw } in
      let ctx' = push_frame ctx frame in
      eval ctx' b

| CapCall { cap; method_; args } ->
    let impl = resolve_cap ctx.env.caps cap in
    let arg_vs = List.map (eval ctx) args in
    dispatch impl method_ arg_vs
```

Host stdlib: `StdoutLogger` constructor returning an `impl_value` whose `info` method calls `print_endline`.

```ocaml
(* lib/stdlib/logger.ml *)
let stdout_logger () : impl_value = {
  ty = "StdoutLogger";
  methods = [ "info", DHost (fun [VStr s] -> print_endline s; VUnit) ];
  cap_env = []; fields = []; drop = None; lifecycle = None;
}
```

Constructor registration: a single host-constructor table mapping `"StdoutLogger" -> (args -> impl_value)`. A bare `StdoutLogger` (fieldless construction, DEC-009) looks up this table.

### Deferred

User-defined impls (Stage 4), capability `extends` (Stage 4), impl-private `requires` (Stage 4), Wiring values (Stage 14), scopes other than `'Process` (Stage 12), Lifecycle (Stage 13).

-----

## Stage 4 — User impls and composition  ✅ *implemented*

### Example

```di
capability Stamper {
    fn stamp(msg: Str) -> Str
}

capability Greeter {
    fn say(msg: Str)
}

struct ExclaimStamper {}
impl Stamper for ExclaimStamper {
    fn stamp(msg: Str) -> Str { "${msg}!" }
}

struct PrefixedGreeter {}
impl Greeter for PrefixedGreeter {
    requires {Stamper}
    fn say(msg: Str) { print(Stamper.stamp(msg)) }
}

fn main() {
    with [
        Stamper <- ExclaimStamper
        Greeter <- PrefixedGreeter
    ] @ 'Process {
        Greeter.say("hello")
    }
}
```

Expected: `hello!`

A second small example adds capability extension:

```di
capability ReadDb { fn query(sql: Str) -> Str }
capability WriteDb extends ReadDb { fn execute(sql: Str) }

struct EchoDb {}
impl ReadDb + WriteDb for EchoDb {
    fn query(sql: Str)  -> Str { "[result: ${sql}]" }
    fn execute(sql: Str) { print("[exec: ${sql}]") }
}

fn show() requires {ReadDb} {                  // demands only ReadDb
    print(ReadDb.query("SELECT 1"))
}

fn main() {
    with [ WriteDb <- EchoDb ] @ 'Process { show() }      // binding WriteDb also satisfies ReadDb
}
```

### What's new

`struct T { fields }`, `impl Cap1 [+ Cap2] for T`, impl-private `requires` (a row on the impl block, syntax §4.2), capability `extends` (syntax §2.3), multi-binding `with [ … ]` blocks where later bindings can reference earlier ones (syntax §7.1, §4.1.7).

**Inherent impls (DEC-022).** A bare `impl T { fn … }` — no `for`, no interface — declares a type's own methods, reached by receiver via value-method dispatch (below). This is the no-interface form, orthogonal to the eventual `trait` (which is still unimplemented — only `capability` exists as an interface decl). It removed the old "marker capability" hack from value types. One token after `impl IDENT` disambiguates inherent (`LBRACE`) from `impl Cap for T` (`FOR`/`PLUS`); `caps = []` on the impl is inert at runtime.

**Value-method dispatch (DEC-020).** `s.f(args)` on any struct/impl value resolves `f` against the value's methods (inherent or `impl Cap for T`), not only through capability dispatch. Value-dispatched user methods run with the **caller's** caps (the value was never wired through a `with`), whereas a capability-dispatched method runs with the impl's captured `cap_env`. Rust method/field rule: `s.f(args)` is always a method call; a field holding a function is invoked `(s.f)(args)`.

This is the stage where the **cap-env capture pattern** is established — the critical mechanic of Dilang's runtime model:

When evaluating `Greeter <- PrefixedGreeter @ 'Process`, the impl value records the **capability environment as of that binding point**, which includes the just-added `Stamper` binding. Calls to `Greeter.say(...)` later dispatch into the impl, whose body uses `Stamper.stamp(...)` — and that `Stamper` resolves against the captured environment, not against the caller's environment.

### Interpreter changes

AST additions:

```ocaml
type decl =
  | ...
  | DStruct of { name : type_name; fields : (ident * ty) list }
  | DImpl of {
      for_ty       : type_name;
      caps         : ident list;          (* `impl A + B for T` *)
      priv_requires : row;                (* private requires row *)
      methods      : impl_method list;
    }

and cap_decl = { ...; extends : ident list }
```

Resolution pass:

- Build `impls_by_cap : (cap, impl_decl list) Hashtbl.t`.
- Compute extension closure: `ext_of : cap -> cap set`. A binding under cap `C` satisfies `C'` if `C' ∈ ext_of C`.
- Reject forward references inside a `with` block (each binding sees only previous ones).

Eval changes:

- The `with [ … ]` block builds bindings *left to right*, with each binding's RHS evaluated against the frame as it stands so far. The impl value captures `cap_env = current_caps_with_partial_frame`. (Spread entries `...wiring_expr` splice a `Wiring`'s recorded bindings at their lexical position — Stage 14.)

```ocaml
let eval_with_block ctx ~scope ~entries ~body =
  Eio.Switch.run @@ fun sw ->
    let scope_name = Option.value scope ~default:"'Process" in
    let built = ref [] in
    List.iter (fun (Binding { cap; rhs; scope = _ }) ->
      let partial = { scope = scope_name; bindings = List.rev !built; switch = sw } in
      let caps_now = partial :: ctx.env.caps in
      let ctx_bind = { ctx with env = { ctx.env with caps = caps_now } } in
      let impl_raw = eval ctx_bind rhs in
      let impl = with_cap_env impl_raw caps_now in    (* capture env for impl-private requires *)
      built := (cap, impl) :: !built;
    ) entries;
    let frame = { scope = scope_name; bindings = List.rev !built; switch = sw } in
    let ctx_body = push_frame ctx frame in
    eval ctx_body body
```

- `dispatch impl method_ args` invokes a user impl method. The method body's `ctx.env.caps` is set to `impl.cap_env` (the impl-private row resolves against the captured environment, not against the caller's). The `self` reference is the impl's own struct value.

```ocaml
let dispatch_user ctx impl method_ args =
  let m = List.assoc method_ impl.methods in
  let activation = {
    values = bind_params m.params args @ self_binding impl;
    caps = impl.cap_env;
  } in
  let ctx' = { ctx with env = activation; defers = ref [] } in
  try eval ctx' m.body with Return_exn v -> v
```

- `resolve_cap` walks `cap_env` outside-in; within each frame it accepts the *last* binding whose extension closure includes the requested name.

Host stdlib: no new constructors; users can now write their own impls in Dilang.

### Deferred

Generic impls (Stage 10 via row vars, full generics deferred to type-checker phase), `extends` chains longer than one link (works the same way). *(Value-method dispatch `value.method()` — once listed here as deferred — is now implemented, DEC-020; see "What's new" above. A named `trait` interface resolved by receiver is still unbuilt and would reuse the same dispatch mechanism.)*

-----

## Stage 5 — Errors and Option  ✅ *implemented*

### Example

```di
enum AppError {
    BadInput(reason: Str)
    NotFound
}

fn divide(a: I64, b: I64) -> I64 raises {AppError} {
    if b == 0 { raise BadInput("zero divisor") }
    a / b
}

fn find_user(id: Str) -> Str? {
    if id == "u1" { "Alice" } else { None }
}

fn main() {
    try {
        print(divide(10, 2))                     // 5
        print(divide(10, 0))                     // raises
    } catch {
        BadInput(reason) -> print("bad: ${reason}")
        NotFound         -> print("not found")
    }

    let name = find_user("u2") ?? return print("missing")
    print("got: ${name}")
}
```

Expected:
```
5
bad: zero divisor
missing
```

### What's new

`enum E { Variant1, Variant2(payload: T) }` (variants comma- or newline-separated, never `;`), `raise X(args)`, `try { … } catch { Variant -> arm, … }` (arms comma- or newline-separated; `_ -> arm` is the wildcard; a single arm may also be written unbraced, `catch Variant(e) -> arm`), the `Never` type via `raise` and `return`, `Option<T>` with sugar `T?`, `None`/`Some(x)`, `??` (null-coalescing with `Never`-RHS support), `?.` (optional chain/call), `if/else`.

### Interpreter changes

AST additions:

```ocaml
type expr =
  | ...
  | If         of expr * expr * expr option
  | Raise      of { variant : ident; payload : expr list }
  | Try        of { body : expr; arms : (pattern * expr) list }
  | NullCoalesce of expr * expr
  | OptChain   of { recv : expr; name : ident }
  | OptCall    of { recv : expr; name : ident; args : expr list }
  | EnumLit    of { ty : type_name option; tag : string; args : expr list }
  | Return     of expr

and pattern =
  | PWild
  | PVar     of ident
  | PVariant of { ty : type_name option; tag : string; sub : pattern list }
```

Value additions:

```ocaml
type value =
  | ...
  | VOpt  of value option
  | VEnum of { ty : type_name; tag : string; payload : value list }
```

Eval:

```ocaml
exception Dilang_error of { tag : string; payload : value list }

| Raise { variant; payload } ->
    raise (Dilang_error { tag = variant; payload = List.map (eval ctx) payload })

| Try { body; arms } ->
    (try eval ctx body
     with Dilang_error err -> match_error_arms ctx err arms)

| NullCoalesce (lhs, rhs) ->
    (match eval ctx lhs with
     | VOpt (Some v) -> v
     | VOpt None     -> eval ctx rhs)       (* rhs may be Never (Return/Raise) *)

| Return e -> raise (Return_exn (eval ctx e))
```

`if/else` is straightforward. `?.` desugars at parse: `x?.f` → `match x with Some v -> Some v.f | None -> None`; same for `x?.m(args)`.

`None` and `Some(x)` are surface syntax for the `Option` stdlib enum. The host stdlib registers `Option` so the parser/resolver knows it.

Exhaustiveness in `try ... catch`: a v0 runtime check — if no arm matches the raised tag, re-raise. (Type-checker enforces it statically later.)

### Deferred

Pattern matching on structs/tuples (add when needed by an example), nested patterns, `Result` (intentionally not in the language).

-----

## Stage 6 — Defer  ✅ *implemented*

### Example

```di
fn handle(name: Str) {
    defer print("cleanup ${name}")
    print("doing ${name}")
}

fn risky() raises {AppError} {
    defer print("risky cleanup")
    raise BadInput("oops")
}

fn main() {
    handle("a")
    handle("b")
    try risky() catch {
        BadInput(_) -> print("caught")
    }
}
```

Expected:
```
doing a
cleanup a
doing b
cleanup b
risky cleanup
caught
```

`defer` is **block-scoped** — see DEC-012 (matches Zig/Swift/D; diverges from Go). A deferred expression runs at the end of the smallest enclosing `{ ... }`, on every exit path from that block: fall-through, `return`, `break`/`continue` (Stage 7+), raised error, cancellation. Each `{ ... }` in surface syntax is its own defer scope — fn body, `if`/`else` branch, `loop`/`while` body, `try`/`catch` body, `with [ … ]` body, bare block expression. Defers within a block fire LIFO. The body expression is evaluated when the defer *fires*, not at registration; reads of mutable state see scope-exit values.

In the example: `handle`'s defer is in the fn body block, fires as that block exits. `risky`'s defer fires as the fn-body block unwinds via raised error, before the raise reaches `main`'s `try`. A defer inside `try { defer X; raise ... }` would fire as that try-body block exited, *before* `catch` ran.

### What's new

`defer expr` registers a finalizer for the enclosing block's exit (any path). Two prior-art models the language explicitly does not adopt:
- Go (function-scoped + args captured at registration) — makes `for { defer release(x) }` a leak, and forces refactoring to recover.
- Function-scoped with body-evaluated-at-fire-time (the v0 sketch this section originally proposed) — same loop footgun, plus reviewer has to scan upward to find the activation boundary.

### Interpreter changes

AST: `Defer of expr` and `Scope of expr`. The parser's `block:` rule wraps the result of `block_of_items` in `Scope`, so every `{ ... }` produces a `Scope`.

Eval: `Defer` pushes a closure onto `ctx.defers`. `Scope` swaps in a fresh `defers : (unit -> unit) list ref`, evaluates the body inside `Fun.protect`, and runs the frame's defers in `finally` (LIFO, per-thunk exceptions swallowed per DEC-011 v0):

```ocaml
| Scope body ->
    let frame = ref [] in
    let ctx' = { ctx with defers = frame } in
    Fun.protect
      ~finally:(fun () -> run_defers !frame)
      (fun () -> eval ctx' body)

| Defer body ->
    let ctx_at_reg = ctx in
    ctx.defers := (fun () -> ignore (eval ctx_at_reg body)) :: !(ctx.defers);
    VUnit
```

Activation boundaries (`call_fn`, `DUser` arm of `CapCall`) own *only* the `Return_exn` catch — defer state belongs to the fn-body's `Scope`, not to the activation. Return raises `Return_exn`; each `Scope`'s `Fun.protect` runs its defers on the way up; `call_fn` catches `Return_exn` at the top and returns the value.

`Cancelled` (Stage 16) and `Panic` slot into the same machinery: any exception propagating through a `Scope` triggers its `Fun.protect` finally.

### Deferred

`Drop` for ordinary values (separate per-value finalizer hook). `errdefer` / `successdefer` for exit-path-conditional cleanup (DEC-011). Stricter policy on defer-body-raises (DEC-011; currently swallowed in v0).

-----

## Stage 7 — Assignment and loops  ✅ *implemented*

### Example

```di
fn main() {
    let mut i   = 0
    let mut sum = 0
    loop {
        if i >= 10 { break }
        sum = sum + i
        i = i + 1
    }
    print(sum)                            // 45

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

### What's new

Mutable rebinding `x = rhs`, legal only where `x` was bound `let mut`. Infinite `loop { ... }`. `while cond { ... }`. `break` and `continue` exit / restart the innermost `loop`/`while`. Loops are statements at v0; they evaluate to `VUnit`.

Stage 1 introduced `let mut` parsing but assignment had no AST node. This stage finishes the surface-level mutability story.

### Interpreter changes

AST:

```ocaml
type expr =
  | ...
  | Assign   of { name : ident; rhs : expr }
  | Loop     of expr                       (* body *)
  | While    of { cond : expr; body : expr }
  | Break
  | Continue
```

Parser: new keywords `LOOP`, `WHILE`, `BREAK`, `CONTINUE`. The `IDENT = expr` form needs lookahead: at `block_item` start, `IDENT EQUALS` parses as `Assign`, otherwise fall through to `expr`. No new shift/reduce conflict if `EQUALS` doesn't appear inside `expr`.

Eval:

```ocaml
exception Break_exn
exception Continue_exn

| Assign { name; rhs } ->
    (match Env.find_ref ctx.env name with
     | Some (r, true)  -> r := eval ctx rhs; VUnit
     | Some (_, false) -> failwith ("cannot assign to immutable `" ^ name ^ "`")
     | None            -> failwith ("unknown name `" ^ name ^ "`"))

| Loop body ->
    (try while true do ignore (eval ctx body) done
     with Break_exn -> ()); VUnit

| While { cond; body } ->
    (try
       while (match eval ctx cond with VBool b -> b | _ -> panic "while cond not bool") do
         try ignore (eval ctx body) with Continue_exn -> ()
       done
     with Break_exn -> ()); VUnit

| Break    -> raise Break_exn
| Continue -> raise Continue_exn
```

Extend `env.values` to carry a `bool` mut flag per binding (or maintain a parallel `mut_names` set). `Let { mut = true }` records the flag at bind time; `Assign` checks before mutating the ref.

Defer (Stage 6) interaction: `break`/`continue` do not cross an activation boundary, so they do not fire defers. `try`/`catch` catches `Dilang_error` only, not `Break_exn`/`Continue_exn`, so a `break` inside a `try` flows out to the enclosing loop as intended. Add a test for both.

### Deferred

Labeled break (`break 'outer`). `for x in iter` is Stage 8 (when arrays land). `do { ... } while`-style post-test is not in the language.

-----

## Stage 8 — Arrays and iteration  ✅ *implemented*

### Example

```di
fn main() {
    let nums = [3, 1, 4, 1, 5, 9, 2, 6]

    let mut max = nums[0]
    for n in nums {
        if n > max { max = n }
    }
    print(max)                            // 9

    let mut doubled = []
    for n in nums {
        doubled.push(n * 2)
    }
    print(doubled.len())                  // 8
    print(doubled[3])                     // 2
}
```

### What's new

`[a, b, c]` array literal. `xs[i]` indexed read (panic on out-of-bounds in v0; later, a typed `[]?` form may return `Option`). `xs.len() -> I64`. `xs.push(v)` (mutating; `xs` must be `let mut`). `for x in xs { body }` iteration over arrays.

Empty array literal `[]` infers element type from context. In the interpreter values are typeless; the type checker enforces uniformity later.

This stage introduces **value-method dispatch** — `xs.len()` is not a capability call. Add a minimal table keyed by host type tag, distinct from `Cap.method(...)`. The parser produces a generic `MethodCall { target; name; args }`; eval branches on the runtime type of `target`. *(This dispatch was later generalized to user structs and `impl` values — DEC-020 — so `s.f(args)` works on any value, not just arrays/strings; see Stage 4.)*

The array **type** `[T]` is also accepted in type position (`fn route(table: [Route])`), erased at runtime — it implements the already-documented syntax §Arrays and added no parser conflicts.

### Interpreter changes

AST:

```ocaml
type expr =
  | ...
  | ArrayLit   of expr list
  | Index      of { target : expr; idx : expr }
  | For        of { var : ident; iter : expr; body : expr }
  | MethodCall of { target : expr; name : ident; args : expr list }
```

Value:

```ocaml
type value =
  | ...
  | VArray of value array ref              (* growable via Array.append *)
```

(Use `Dynarray.t` if the OCaml version is recent enough; otherwise a plain `value array ref` with manual growth is fine — these arrays are short.)

Eval:

```ocaml
| ArrayLit es ->
    VArray (ref (Array.of_list (List.map (eval ctx) es)))

| Index { target; idx } ->
    (match eval ctx target, eval ctx idx with
     | VArray a, VInt i ->
         let i = Int64.to_int i in
         if i < 0 || i >= Array.length !a then panic "index out of bounds";
         (!a).(i)
     | _ -> panic "indexing non-array")

| For { var; iter; body } ->
    (match eval ctx iter with
     | VArray a ->
         (try
            Array.iter (fun v ->
              let env' = Env.bind ctx.env var ~mut:false v in
              try ignore (eval { ctx with env = env' } body)
              with Continue_exn -> ()) !a
          with Break_exn -> ());
         VUnit
     | _ -> panic "for over non-iterable")

| MethodCall { target; name = "len"; args = [] } ->
    (match eval ctx target with
     | VArray a -> VInt (Int64.of_int (Array.length !a))
     | VStr s   -> VInt (Int64.of_int (String.length s))     (* Stage 9 reuses this arm *)
     | _ -> panic "len on unsupported type")

| MethodCall { target; name = "push"; args = [v] } ->
    (match eval ctx target with
     | VArray a ->
         a := Array.append !a [| eval ctx v |]; VUnit
     | _ -> panic "push on non-array")
```

`for` over an array reuses `Break_exn`/`Continue_exn` from Stage 7. The eval loop is unconditionally iterative — no generator suspension here; that's Stage 17.

### Deferred

A general `Iterator<T>` trait dispatch. `for` over user-defined iterables. Slicing (`xs[a..b]`). `map`/`filter`/`fold` (need closures, Stage 10). `pop`, `get`, `insert`, `remove` can be added as demos demand — keep the bare set tight until then.

-----

## Stage 9 — Strings  ✅ *implemented*

### Example

```di
fn main() {
    let s = "GET /users/42 HTTP/1.1"

    print(s.len())                              // 22
    print(s.starts_with("GET"))                 // true
    print(s.contains("/users/"))                // true

    let parts = s.split(" ")
    print(parts.len())                          // 3
    print(parts[1])                             // /users/42

    let trimmed = "  hello  ".trim()
    print("[${trimmed}]")                       // [hello]
}
```

### What's new

`Str` gains value-method-dispatch (reusing Stage 8's `MethodCall` plumbing):

- `.len() -> I64`
- `.contains(needle: Str) -> Bool`
- `.starts_with(prefix: Str) -> Bool`
- `.ends_with(suffix: Str) -> Bool`
- `.split(sep: Str) -> [Str]`
- `.trim() -> Str`

No string mutation in v0. No char-level operations — `.chars()` and indexing are deferred.

### Interpreter changes

AST: nothing new. Method dispatch is the Stage 8 mechanism.

Eval: extend the value-method-dispatch table for `VStr`. Implementations are direct calls to `Stdlib.String` (`String.length`, `String.starts_with`, `String.ends_with`, `String.trim`). `.contains` and `.split` for multi-character separators need a small handwritten substring scanner (~15 lines) since `Stdlib.String.split_on_char` only accepts a single char.

```ocaml
| MethodCall { target; name = "split"; args = [sep] } ->
    (match eval ctx target, eval ctx sep with
     | VStr s, VStr sep ->
         let pieces = String_util.split_on_substring s sep in
         VArray (ref (Array.of_list (List.map (fun p -> VStr p) pieces)))
     | _ -> panic "split on non-string")
```

`"" .split(sep)` returns `[""]`. `s.split("")` is rejected with a panic in v0 (defining "split on empty" is ambiguous; the type checker can later enforce a non-empty-separator precondition).

### Deferred

`.chars()` returning an iterator/array of chars. Indexed access `s[i]`. Unicode-aware operations. `.replace`, `.to_lower`, `.to_upper` — add as demos demand. String builders / `StringBuilder` host type only if performance bites in practice (string `+` is fine for now).

-----

## Stage 10 — Closures  ✅ *implemented*

### Example

```di
capability Logger { fn info(msg: Str) }

enum RetryError { GiveUp }

fn with_retry(times: I64, action: fn() -> I64) -> I64
    requires {Logger}
    raises   {GiveUp}
{
    let mut i = 0
    loop {
        try {
            return action()
        } catch {
            _ -> {
                i = i + 1
                Logger.info("attempt ${i} failed")
                if i >= times { raise GiveUp }
            }
        }
    }
}

fn main() {
    with [ Logger <- StdoutLogger ] @ 'Process {
        let result = with_retry(3, || {
            Logger.info("attempting")
            42
        })
        print(result)
    }
}
```

Expected:
```
attempting
42
```

(`catch` takes `pattern -> arm` arms inside braces — `catch { _ -> { … } }` — not `catch _ { … }`. The arm body may itself be a block. A single arm can also be written unbraced: `catch DbError(e) -> raise …`.)

### What's new

Lambda syntax `|params| body` (and the braced-body form `|params| { … expr }`, statements newline-separated), plus the zero-arg form `|| body` (DEC-021: `||` lexes as one token; the spaced `| |body` is two `PIPE`s). First-class function values with type `fn(T1, T2) -> R`. Closures capture their lexical environment by reference at the point of definition, **including the capability stack** at that point.

Effect rows on closures are inferred but stored on the value, not statically checked yet. The type checker will consume them later.

This stage explicitly does **not** ship row-polymorphic generics (`fn with_logging<R, E>(f: fn() -> Unit requires {R} raises {E})`). Closures work; passing them around works; capturing capabilities works. Row variables and quantification are deferred to the type-checker phase — they pay rent there, not in the interpreter.

### Interpreter changes

AST:

```ocaml
type expr =
  | ...
  | Lambda of { params : (ident * ty option) list; body : expr }
```

Value:

```ocaml
type value =
  | ...
  | VClosure of {
      params : (ident * ty option) list;
      body   : expr;
      env    : env;                 (* captured value environment *)
      caps   : cap_env;             (* captured capability stack *)
    }
```

Eval:

```ocaml
| Lambda { params; body } ->
    VClosure { params; body; env = ctx.env; caps = ctx.caps }

(* extend Call to handle closure values *)
| Call { fn; args } ->
    (match eval ctx fn with
     | VClosure { params; body; env; caps } ->
         let arg_vs = List.map (eval ctx) args in
         if List.length params <> List.length arg_vs then
           failwith "arity mismatch";
         let env' = List.fold_left2
           (fun e (p, _) v -> Env.bind e p ~mut:false v)
           env params arg_vs
         in
         let defers = ref [] in
         let ctx' = { ctx with env = env'; caps; defers } in
         Fun.protect
           ~finally:(fun () -> List.iter (fun t -> try t () with _ -> ()) !defers)
           (fun () -> try eval ctx' body with Return_exn v -> v)
     | VFn fd -> call_fn ctx fd (List.map (eval ctx) args)
     | _ -> panic "call of non-function")
```

The `caps` capture is the load-bearing piece for Stage 11: a closure defined inside a `with [ Logger <- … ] @ 'Process { … }` block carries the `Logger` binding with it, so when an HTTP server invokes the closure later (outside that lexical block), `Logger` is still resolvable. Add an explicit test where a closure is stored in a `let`, the `with` block exits, then the closure is invoked from outside — the capability lookup must still succeed.

Free function names become callable as values: `let f = foo; f(1)` works. Extend the lookup chain in `eval (Var name)` to consult the fns table after env.

Activations created by closure calls own their own `defers` ref (matching the Stage 6 discipline for `fn` calls). Defers registered inside a lambda body fire when the lambda's call returns, not when the lambda is constructed.

### Deferred

Row-polymorphic generics (`<R, E>` variables on function types). Polymorphic identity functions over rows. Trait-bounded generics. Closure-converted optimisations.

-----

## Stage 11 — HTTP server and client  ✅ *implemented*

### Example

```di
fn main() {
    with [
        Logger     <- StdoutLogger
        HttpServer <- BlockingHttpServer
    ] @ 'Process {
        Logger.info("listening on :8080")

        HttpServer.serve(8080, |req| {
            Logger.info("${req.method} ${req.path}")

            if req.path.starts_with("/echo/") {
                Response { status: 200, body: req.path }
            } else if req.path == "/health" {
                Response { status: 200, body: "ok" }
            } else {
                Response { status: 404, body: "not found" }
            }
        })
    }
}
```

Run with `dilang run service.di`; from another terminal, `curl localhost:8080/health` → `ok`. (The shipped fixtures use port **18080**, not 8080.)

### What's new

The **first network-facing capability**. Stdlib registers the data types and the host impls register against them.

```di
capability HttpServer @ 'Process {
    fn serve(port: I64, handler: fn(Request) -> Response)
}

capability HttpClient @ 'Process {
    fn get(url: Str) -> Response                raises {HttpError}
    fn post(url: Str, body: Str) -> Response    raises {HttpError}
}

struct Request  { method: Str, path: Str, body: Str }
struct Response { status: I64, body: Str }
enum HttpError {
    ConnectionFailed(reason: Str)
    BadStatus(code: I64)
    InvalidUrl(url: Str)
}
```

`Request` has **no `headers` field** in v0: header ergonomics are deferred until a tuple/map value model exists (DEC-019). The host parses requests/responses with bodies only (`Content-Length`-gated), no header surface to user code yet.

Host impls landed in this stage:

- `BlockingHttpServer` — single connection at a time. Backed by `Eio.Net.run_server` with `max_connections = 1`. Each request runs the handler closure to completion before the next `accept`. User code sees a blocking model; the host hides the fiber.
- `BlockingHttpClient` — synchronous `get`/`post`. Backed by `cohttp-eio`, or `Eio.Process` shelling out to `curl` if the cohttp dependency is too heavy in v0. Whichever is faster to land.

Both impls require an `Eio.Switch.t`. Reuse the per-`with`-block switch already stashed on the cap_frame (set up in Stage 3, unused until now).

### Interpreter changes

AST: nothing new. This stage is closures + a host capability.

Host stdlib changes:

- Register `Request`, `Response` structs and `HttpError` enum at startup. Use the same path as `Option`/`Some`/`None` from Stage 5 (`ctx.user_constructors` for structs, `ctx.variants` for the enum).
- Implement `BlockingHttpServer` as a `DHost` impl. The `serve` method:
  1. Opens (or reuses) the per-`with`-block `Eio.Switch.t`.
  2. Calls `Eio.Net.run_server ~max_connections:1 ~on_error:Logger.error` against an `Eio.Net.listening_socket`.
  3. For each accepted connection: parses HTTP/1.1 request → `Request` struct value, invokes the closure via the same path `Call` uses for `VClosure`, formats the returned `Response`, writes it back.
  4. `Ctrl-C` cancels the switch cleanly — the server's `Eio.Switch.run` unwinds, defers fire, connections close.

The handler closure is a `VClosure` carrying its captured `Logger`. Invoking it from inside the host uses the captured `caps` — exactly what Stage 10 set up. **Verify with a test** that a `with` binding outside `HttpServer.serve` is visible inside the handler, and that swapping `StdoutLogger` for a different impl at `main` changes the handler's output with no other code changes.

### CLI

`dilang run service.di` blocks in the accept loop. Add `dilang run --max-requests N service.di` so smoke tests can run the server, send a few requests, and have it exit deterministically. The `--max-requests` flag is interpreter-level, not exposed to user code — it just sets a counter the `BlockingHttpServer` consults.

### Test posture

Don't try to bind ephemeral ports inside `alcotest` cases on every CI run yet. The deliverable is:

1. `test/programs/http_hello/service.di` running under `dilang run --max-requests 3`. A small OCaml test fixture forks `dilang run`, fires three requests via a raw socket, asserts the responses, then waits for the child to exit.
2. A `BlockingHttpClient` test that hits the running service from inside the same fixture.

Once Stage 19 (Tests) lands, an in-process `MockHttpServer` impl makes this hermetic.

### Deferred

- Per-request scoping (`@ 'Request` bindings around the handler) — Stage 12.
- DB pool with `Lifecycle` start/shutdown — Stage 13.
- Concurrent request handling (>1 in flight) — Stage 15 swaps `BlockingHttpServer` for `EioHttpServer`.
- Per-request timeouts — Stage 16.
- Streaming response bodies, chunked transfer encoding, server-sent events — Stage 17.
- HTTPS, HTTP/2, websockets — not on the immediate roadmap.

-----

## Milestone 11.5 — HTTP service with route table  ✅ *shipped*

No new language features. Ship a complete program at `test/programs/router/service.di` that exercises everything through Stage 11:

```di
struct Route { method: Str, prefix: Str, handler: fn(Request) -> Response }

fn route(req: Request, table: [Route]) -> Response {
    for r in table {
        if req.method == r.method && req.path.starts_with(r.prefix) {
            return (r.handler)(req)
        }
    }
    Response { status: 404, body: "no route" }
}

fn health(_: Request) -> Response { Response { status: 200, body: "ok" } }

fn echo(req: Request) -> Response {
    Response { status: 200, body: req.body }
}

fn main() {
    with [
        Logger     <- StdoutLogger
        HttpServer <- BlockingHttpServer
    ] @ 'Process {
        let table = [
            Route { method: "GET",  prefix: "/health", handler: health },
            Route { method: "POST", prefix: "/echo",   handler: echo }
        ]

        HttpServer.serve(8080, |req| {
            Logger.info("${req.method} ${req.path}")
            route(req, table)
        })
    }
}
```

Two grammar points this program turns on, both now implemented:
- **`(r.handler)(req)`, not `r.handler(req)`.** `Route.handler` holds a `fn(Request) -> Response` value. By the Rust method/field rule (DEC-020) `r.handler(req)` is a *method* call (and errors with a field-vs-method hint); calling a field that holds a function needs the parenthesised general-call form `(r.handler)(req)`.
- **Short-circuit `&&` (DEC-021)** joins the method and path-prefix tests.

This is the **first dilang program worth showing someone**. It exercises: closures (handler refs), arrays (route table), strings (path matching, body), structs (`Request`, `Response`, `Route`), capabilities + `with` wiring (Logger swap), control flow (`for`, `if`, `return`), and value-method dispatch on the `Route` value.

Add to `dune runtest` as a smoke test: launch the service via `dilang run --max-requests 6`, fire `health` / `echo` / unknown-route / wrong-method requests from a fixture, assert the four responses, wait for clean exit.

Goal of this milestone: validate the closure+capability story against a running program before introducing the more invasive machinery (scopes, Lifecycle, Wiring) in Stages 12–14.

-----

## Stage 12 — Scopes  🔜 *next; not yet built*

### Example

```di
scope 'Request under 'Process

capability ReqId @ 'Request {
    fn get() -> Str
}

struct StaticReqId { id: Str }
impl ReqId for StaticReqId {
    fn get() -> Str { self.id }
}

fn show_id() requires {ReqId} {
    print("request: ${ReqId.get()}")
}

fn main() {
    with [
        ReqId <- StaticReqId { id: "abc-123" }
    ] @ 'Request {
        show_id()
    }

    with [
        ReqId <- StaticReqId { id: "xyz-789" }
    ] @ 'Request {
        show_id()
    }
}
```

Expected:
```
request: abc-123
request: xyz-789
```

Each `with [ … ] @ 'Request` creates a fresh frame; the bindings are local to it.

### What's new

`scope 'X under 'Parent` top-level declaration (RFC-001 §1.1: lifetime names are apostrophe-prefixed, nesting via `under`), `@ 'X` scope annotation on capability declarations and on bindings, `with [ … ] @ 'X { … }`. Re-entering the `with` block per call yields a fresh instance. Bindings without an explicit `@` inherit the block's `'X`.

### Interpreter changes

AST:

```ocaml
type decl = ... | DScope of { name : lifetime; parent : lifetime option }

type cap_decl = { ...; scope : lifetime option }   (* None = any *)

(* WithCaps already carries `scope : lifetime option` and per-entry scopes from Stage 3 *)
```

Eval: nothing fundamentally new — `WithCaps` already constructs a frame tagged with the scope name (Stage 3 left it as `"'Process"` if absent). The scope tag is recorded in the frame; v0 doesn't enforce scope-escape checks (that's the type checker's job).

Lookup is unchanged: capability resolution walks frames outside-in regardless of scope tag. The scope tag is *informational* in v0 — used by the type checker, observable in error messages.

Struct literal syntax `StaticReqId { id: "abc-123" }` needs parser + eval support:

```ocaml
type expr = ... | StructLit of { ty : type_name; fields : (ident * expr) list; spread : expr option }

(* eval *)
| StructLit { ty; fields; spread = None } ->
    let fs = List.map (fun (n, e) -> (n, ref (eval ctx e))) fields in
    VStruct { ty; fields = fs }
```

`self` in impl methods now reads from the struct fields of `impl.fields`.

### Deferred

Static enforcement that a `@ 'Request`-scoped capability isn't bound or used outside a `'Request` scope. v0 lets it slide; the type checker enforces (§4.1.3).

-----

## Stage 13 — Lifecycle  ⏳ *planned; not yet built*

### Example

```di
scope 'Transaction under 'Process

capability DbConn @ 'Transaction {
    fn execute(sql: Str)
}

struct PgConn {}
impl DbConn for PgConn {
    fn execute(sql: Str) { print("> ${sql}") }
}

impl Lifecycle for PgConn {
    fn start() raises {} {
        print("BEGIN")
    }
    fn shutdown(exit: ExitReason) {
        match exit {
            Normal    -> print("COMMIT")
            Raised(_) -> print("ROLLBACK")
            Panicked  -> print("ABORT")
        }
    }
}

fn transfer() raises {AppError} {
    with [
        DbConn <- PgConn
    ] @ 'Transaction {
        DbConn.execute("UPDATE x SET y = 1")
        // normal exit → COMMIT
    }
}

fn fail() raises {AppError} {
    with [
        DbConn <- PgConn
    ] @ 'Transaction {
        DbConn.execute("UPDATE x SET y = 1")
        raise BadInput("nope")
    }
}

fn main() {
    transfer()
    try fail() catch BadInput(_) -> print("caught")
}
```

(`PgConn` is fieldless, so it constructs bare — `PgConn`, not `PgConn {}` — per DEC-009.)

Expected:
```
BEGIN
> UPDATE x SET y = 1
COMMIT
BEGIN
> UPDATE x SET y = 1
ROLLBACK
caught
```

### What's new

`Lifecycle` trait — `start()` and `shutdown(exit: ExitReason)`. Detected on impl values when they're bound in a `with` block. Runs on entry/exit in topological order of `start.requires`, with ties broken by lexical order (design §3.6.3). Started impls roll back in reverse on partial-start failure (§3.6.4).

`ExitReason` is a stdlib enum: `Normal | Raised(Error) | Panicked`.

### Interpreter changes

AST: nothing new — `Lifecycle` is a regular capability/trait impl. The interpreter recognises it structurally.

Resolution: when building an impl value, detect whether an `impl Lifecycle for T` exists for `T`'s type and attach its `start`/`shutdown` methods plus the `start.requires` row to `impl.lifecycle`.

```ocaml
type lifecycle = {
  start    : ctx -> unit;
  shutdown : ctx -> exit_reason -> unit;
  start_requires : ident list;
}

type impl_value = { ...; lifecycle : lifecycle option }
```

Eval — extend `eval_with_block`:

```ocaml
let eval_with_block ctx ~scope ~entries ~body =
  Eio.Switch.run @@ fun sw ->
    let bindings = build_bindings ctx ~sw ~scope entries in
    let order = topo_sort_starts bindings in
    let exit_reason_ref = ref ExNormal in
    List.iter (fun (cap, impl) ->
      match impl.lifecycle with
      | None -> ()
      | Some lc ->
          lc.start ctx;     (* may raise; switch unwinds via on_release *)
          Eio.Switch.on_release sw (fun () ->
            try lc.shutdown ctx !exit_reason_ref with _ -> ())
    ) order;
    let frame = ... in
    let ctx_body = push_frame ctx frame in
    (try eval ctx_body body
     with
     | Dilang_error err as e -> exit_reason_ref := ExRaised err; raise e
     | Panic _ as e          -> exit_reason_ref := ExPanicked; raise e)
```

Notes:

- `on_release` runs LIFO, matching reverse-of-start order. We register in start order, so LIFO unwinding gives the right order automatically.
- If a `start` raises, only the impls that already started have `on_release` registered, so they shut down with `ExRaised _` (set when the body raises) and the failing impl isn't asked — matching §3.6.4.
- `topo_sort_starts`: build a DAG from `start.requires` (start of impl X depends on impls of the caps in X.start.requires being already started); break ties by lexical position; reject cycles (panic in v0; static error in the type checker).

Stdlib enum `ExitReason` registered with the resolver.

### Deferred

Per-scope-instance Lifecycle cost analysis (design §5.8). The interpreter runs whatever's there.

-----

## Stage 14 — Wiring values  ⏳ *planned; not yet built*

### Example

```di
fn dev_runtime() -> Wiring = with [
    Logger <- StdoutLogger @ 'Process
]

fn dev_repos() -> Wiring = with [
    Greeter <- PrefixedGreeter @ 'Process
    Stamper <- ExclaimStamper  @ 'Process
]

fn main() {
    with [
        ...dev_runtime()
        ...dev_repos()
        Stamper <- QuietStamper @ 'Process         // overrides dev_repos's Stamper
    ] {
        Greeter.say("hello")
    }
}
```

Assuming `QuietStamper.stamp(m) -> m`, output is `hello`.

### What's new

`with [ … ]` with no body produces a `Wiring` value (RFC-001 §1.5). `...wiring_expr` splices a Wiring's entries into the enclosing `with` at that lexical position (RFC-001 §1.4), replacing the old `using`. Lexical order determines override; later wins (syntax §7). A bodyless mixed-scope `with [ … ]` requires every direct binding to carry `@ 'Scope`; a bodyless `with [ … ] @ 'Scope` defaults its direct bindings to `'Scope`.

### Interpreter changes

AST already has `WithCaps { body = None }` and `Spread of expr` entries from Stage 3 (RFC-001) — we just hadn't given them eval semantics.

Value: `VWiring of wiring`.

```ocaml
type wiring = {
  default_scope : lifetime;
  entries       : (ident * Ast.expr * lifetime option) list;  (* (cap, rhs, scope) *)
  ctx_at_construction : ctx;
}
```

Eval:

```ocaml
| WithCaps { entries; scope; body = None } ->
    VWiring {
      default_scope = Option.value scope ~default:"'Process";
      entries = entries |> List.filter_map (function
        | Binding { cap; rhs; scope } -> Some (cap, rhs, scope)
        | Spread _ -> failwith "nested spread inside a Wiring-producing `with` isn't legal at v0");
      ctx_at_construction = ctx;
    }
```

In `eval_with_block`, flatten entries before processing:

```ocaml
let flatten_entries ctx entries =
  List.concat_map (function
    | Binding { cap; rhs; scope } -> [(cap, rhs, scope, ctx)]
    | Spread w_expr ->
        (match eval ctx w_expr with
         | VWiring w -> List.map (fun (c, r, s) -> (c, r, s, w.ctx_at_construction)) w.entries
         | _ -> panic "... spread requires a Wiring value")
  ) entries
```

A spliced binding's RHS is evaluated against the *captured* `ctx_at_construction`, except its `cap_env` is whatever the enclosing `with` has built so far (which is the standard rule). The captured ctx supplies value-environment names that the Wiring function referenced.

Lexical override: `built := (cap, impl) :: !built` always appends. Lookup walks the bindings list back-to-front; later entry wins.

### Deferred

Static "same binding set on every call" check (DEC-003) — type-checker phase. v0 trusts the program.

-----

## Milestone 14.5 — Service with `@ 'Request`, DB pool, dev/test/prod wirings  ⏳ *planned; not yet built*

No new language features. Extend the Stage 11.5 router service to use everything from Stages 12–14:

```di
scope 'Request under 'Process

capability RequestId @ 'Request {
    fn get() -> Str
}
capability ReqLogger @ 'Request {
    fn info(msg: Str)
    fn error(msg: Str)
}
capability TaskDb @ 'Process {
    fn list_open() -> [Task]
    fn create(title: Str) -> Task
}

struct PgTaskDb { pool: ConnPool }
impl TaskDb for PgTaskDb { ... }
impl Lifecycle for PgTaskDb {
    fn start()                  { self.pool.warm() }
    fn shutdown(_: ExitReason)  { self.pool.drain() }
}

fn prod_runtime() -> Wiring = with [
    Logger     <- JsonLogger                                              @ 'Process
    TaskDb     <- PgTaskDb { pool: ConnPool.new(env("DATABASE_URL"), 16) } @ 'Process
    HttpServer <- BlockingHttpServer                                      @ 'Process
]

fn test_runtime() -> Wiring = with [
    Logger     <- TestLogger     @ 'Process
    TaskDb     <- InMemoryTaskDb @ 'Process
    HttpServer <- MockHttpServer @ 'Process
]

fn main() {
    with [ ...prod_runtime() ] {
        HttpServer.serve(8080, |req| {
            with [
                RequestId <- RandomRequestId
                ReqLogger <- PrefixedLogger { prefix: RequestId.get() }
            ] @ 'Request {
                route(req)
            }
        })
    }
}
```

Goals:

- `Lifecycle.start` warms the pool once at process start; `Lifecycle.shutdown` drains it on `Ctrl-C`. Add a `defer` in `main` and a test that asserts the pool's connection count drops to zero on exit.
- `@ 'Request` bindings are fresh per incoming request. `RequestId` is a UUID; `ReqLogger` prefixes log lines with it. Two concurrent requests (mocked) show interleaved logs with distinct prefixes.
- Swapping `prod_runtime()` for `test_runtime()` at `main` changes nothing else in the program. Run the same handler logic under both; assert the test variant produces deterministic output.

This is the milestone where dilang's claims about DI become demonstrable on a running backend service, not on paper. It also exposes the seams where the next stages must work — concurrent request handling (Stage 15), per-request timeouts (Stage 16), streaming responses (Stage 17).

Ship under `test/programs/task_service/`. Three sub-targets: `service.di` (the program), `prod_wiring.di` and `test_wiring.di` (the two `Wiring` modules), and a runtest entry that exercises the test wiring end-to-end.

-----

## Stage 15 — Concurrency via IO  ⏳ *planned; not yet built*

### Example

```di
fn main() {
    with [
        IO <- FiberRuntime { workers: 2 }
    ] @ 'Process {
        let f1 = IO.spawn(|| {
            IO.sleep(100.millis)
            42
        })
        let f2 = IO.spawn(|| {
            IO.sleep(50.millis)
            99
        })
        print("waiting...")
        let a = f1.await()
        let b = f2.await()
        print("got ${a} and ${b}")
    }
}
```

Expected (order between sleeps is deterministic by Eio's scheduling, but spec-wise: f2 finishes first):
```
waiting...
got 42 and 99
```

### What's new

`IO` capability (user-declared per program; the language doesn't built it in — but the host stdlib provides `FiberRuntime` and `TestIO` impls). `IO.spawn(f) -> Future<R, E>`. `Future.await() -> R raises {E}`. `Future.value()`. `Group<R, E>` for accumulating concurrent tasks. `IO.sleep(d)`. Duration literals like `100.millis`.

### Interpreter changes

AST: probably nothing — `100.millis` may need a special-case parser rule (method call on an int literal that constructs a `Duration` value), but otherwise this stage is host-stdlib work.

Value:

```ocaml
type value =
  | ...
  | VFuture of { promise : value Eio.Promise.or_exn; ... }
  | VGroup  of { switch : Eio.Switch.t; ... }
  | VDur    of float                    (* seconds *)
```

Eio threading: every call needs the *current* `Eio.Switch.t`. Until now we've been opening a switch in the `with` block and stashing it in the frame, but we haven't threaded "current switch" through host calls. Add `ctx.sw : Eio.Switch.t` and use the innermost `with`-block frame's switch (or, for `IO.spawn`, the `'Process` switch since spawned fibers should outlive `'Request` scopes).

Host stdlib:

- `FiberRuntime { workers }` constructor — returns an impl_value whose `spawn` calls `Eio.Fiber.fork_promise ~sw:ctx.sw_process`, whose `sleep(d)` calls `Eio.Time.sleep`, etc.
- `Future` — wrapping `Eio.Promise.or_exn`. Trait dispatch on `value.method()` is needed for `f1.await()` syntax. Add minimal trait dispatch: host types declare a methods table; resolution by value's runtime type.
- `Group` — wraps a long-lived `Switch`. `g.concurrent(f)` does `Fiber.fork ~sw:g.switch`. `g.await()` closes the switch.
- `Mutex` — wraps `Eio.Mutex`. (Needed by `InMemoryTaskRepo`-style in-memory repos in tests later.)

`TestIO` constructor backed by `Eio_mock.Backend` is the deterministic alternative — exposed for tests.

### Deferred

`Channel<T>`, signals, networking (`IO.bind/accept`), file system. Add as later examples demand.

-----

## Stage 16 — Cancellation  ⏳ *planned; not yet built*

### Example

```di
fn main() {
    with [ IO <- FiberRuntime ] @ 'Process {
        try with_timeout(50.millis, || {
            IO.sleep(500.millis)
            print("never prints")
        }) catch Timeout -> print("timed out")

        let result = IO.with_cancel(|tok| {
            let winner = IO.spawn(|| { IO.sleep(20.millis)  "fast" })
            let loser  = IO.spawn(|| { IO.sleep(200.millis) "slow" })
            let w = winner.await()
            tok.trip()              // cancels loser
            w
        })
        print("winner: ${result}")

        let conn = acquire_conn()
        defer release(conn)
        uncancellable {
            commit(conn)            // not interruptible
        }
    }
}
```

Expected (modulo `acquire_conn`/`commit`/`release` being defined or stubbed):
```
timed out
winner: fast
```

### What's new

`IO.with_cancel(|tok| { ... })`, `tok.trip()`, the `Cancelled` error, `uncancellable { ... }`, `with_timeout(d, action)` (stdlib helper, not a primitive — syntax §15.2). `select { arm, arm }` for racing (arms comma/newline-separated, never `;`).

### Interpreter changes

AST:

```ocaml
type expr =
  | ...
  | Uncancel of expr
  | Select   of (expr * expr) list           (* (poll, arm) pairs *)
```

Eval:

```ocaml
| Uncancel e ->
    Eio.Cancel.protect (fun () -> eval ctx e)
```

Bridging Eio cancellation:

- Wrap every host call that may suspend in a translator: catch `Eio.Cancel.Cancelled` and re-raise as `Dilang_error { tag = "Cancelled"; payload = [] }` so user `try ... catch Cancelled -> ...` works.
- Defer chains run on `Cancelled` because it's just an exception flowing through `Fun.protect`.

Host stdlib:

- `with_cancel(f)` opens `Eio.Switch.run` for a cancel scope, builds a `VCancel { switch }` token, passes to `f`. `tok.trip()` calls `Eio.Switch.fail tok.switch (Eio.Cancel.Cancelled)`.
- `with_timeout(d, action)` is implemented as Dilang source loaded at startup (the syntax §15.2 helper), or as a host built-in:
  ```di
  fn with_timeout<T>(d: Duration, action: fn() -> T) -> T
      requires {IO} raises {Timeout}
  {
      IO.with_cancel(|tok| {
          IO.spawn(|| {
              IO.sleep(d)
              tok.trip()
          })
          action()
      })
  }
  ```
  Plus catching `Cancelled` raised from `action` and re-raising as `Timeout` (with a private flag distinguishing timer-trip from external cancel).
- `select` arms are forked into a Switch; each pushes its arm index onto an `Eio.Stream`. The select expression takes the first item and runs the matching arm. Losers keep running (syntax §15.4).

### Deferred

Fine-grained cancellation policy choices, structured concurrency lints. The Eio defaults are good enough.

-----

## Stage 17 — Streams  ⏳ *planned; not yet built*

### Example

```di
fn ints_from(start: I64) -> Stream<I64> {
    stream {
        let mut i = start
        loop {
            yield i
            i = i + 1
        }
    }
}

fn main() {
    let mut total = 0
    for n in ints_from(10) {
        total = total + n
        if n >= 14 { break }
    }
    print(total)                      // 10+11+12+13+14 = 60
}
```

Expected: `60`.

### What's new

`stream { ... yield x ... }` produces a `Stream<T>` — a suspending iterator whose producer runs on its own fiber and rendezvous with the consumer on each `yield`. `for x in stream { body }` consumes it.

Loops, `break`/`continue`, mutable reassignment, and `for x in xs` over arrays are already shipped (Stages 7 and 8). This stage adds **the suspending variant**: a `for` over a `VStream` blocks the producer until the consumer takes, and cancelling the consumer kills the producer fiber (so its defers fire).

### Interpreter changes

AST:

```ocaml
type expr =
  | ...
  | Stream of expr             (* the producer body *)
  | Yield  of expr
```

`For` already exists (Stage 8). Extend its eval arm to branch on the runtime type of the iterator value (`VArray` → Array.iter loop; `VStream` → blocking take loop).

Value:

```ocaml
type value = ... | VStream of stream_handle

and stream_handle = {
  chan     : value Eio.Stream.t;     (* capacity 0 — rendezvous *)
  producer : Eio.Switch.t;           (* cancel to stop the producer fiber *)
  closed   : bool ref;
}
```

Eval:

```ocaml
| Stream body ->
    let chan = Eio.Stream.create 0 in
    let closed = ref false in
    Eio.Fiber.fork ~sw:ctx.sw (fun () ->
      try
        let ctx' = { ctx with yield_to = Some chan } in
        ignore (eval ctx' body);
        closed := true
      with _ -> closed := true);
    VStream { chan; closed; producer = ctx.sw }

| Yield e ->
    (match ctx.yield_to with
     | Some chan -> Eio.Stream.add chan (eval ctx e); VUnit
     | None -> panic "yield outside stream")

(* extend the existing For arm to handle VStream as well as VArray *)
| For { var; iter; body } ->
    (match eval ctx iter with
     | VArray a -> (* Stage 8 path, unchanged *)
     | VStream sh ->
         let rec loop () =
           if !(sh.closed) then ()
           else
             let v = Eio.Stream.take sh.chan in
             let env' = Env.bind ctx.env var ~mut:false v in
             (try ignore (eval { ctx with env = env' } body)
              with Continue_exn -> ());
             loop ()
         in
         (try loop () with Break_exn -> ());
         VUnit
     | _ -> panic "for over non-iterable")
```

When the consumer `break`s (or its enclosing scope ends), cancel the producer fiber so its `defer`s run.

### Deferred

A general `Iterator<T>` trait so user types can implement iteration. `stream`-of-stream composition (lazy `.map` / `.filter` over streams) — buildable in user code once row-polymorphic closures land in the type checker.

-----

## Stage 18 — Stdin and filesystem capabilities  ⏳ *planned; not yet built*

### Example

```di
fn main() {
    with [
        Logger      <- StdoutLogger
        StdinReader <- RealStdin
        FsRead      <- RealFs
    ] @ 'Process {
        let path = StdinReader.line() ?? "/etc/hostname"
        try {
            let contents = FsRead.read_to_string(path)
            Logger.info("read ${contents.len()} bytes from ${path}")
            print(contents.trim())
        } catch FileNotFound(p) -> Logger.error("missing: ${p}")
    }
}
```

### What's new

The capabilities a backend service actually needs alongside HTTP:

```di
capability StdinReader @ 'Process {
    fn line() -> Str?                         // None on EOF
    fn read_to_end() -> Str
}

capability FsRead @ 'Process {
    fn read_to_string(path: Str) -> Str       raises {FileNotFound, IoError}
    fn exists(path: Str) -> Bool
}

capability FsWrite @ 'Process {
    fn write_string(path: Str, body: Str)     raises {IoError}
    fn append_string(path: Str, body: Str)    raises {IoError}
}

enum FileNotFound { FileNotFound(path: Str) }
enum IoError      { IoError(reason: Str) }
```

These complete the "real I/O" story for backend services: config loading from disk, log file output, reading request bodies from stdin in test harnesses. Without these, a dilang program cannot read its own configuration — the language has been pretending file I/O exists in the design docs without an interpreter path for it.

### Interpreter changes

AST: nothing new.

Host stdlib:

- `RealStdin` — backed by `Eio.Buf_read` over `stdin`. `line()` returns `Some s` until EOF, then `None`.
- `RealFs` — `Eio.Path` reads under the cwd. Errors translate to `FileNotFound` (when `Eio.Fs.Not_found` is raised) or `IoError` (everything else).
- `RealFsWrite` — same but for writes. Append is `Eio.Path.with_open_out ~append:true`.

Test impls (used by Stage 19):

- `ScriptedStdin { lines: [Str] }` — returns lines from a fixed list, then `None`.
- `InMemoryFs { files: [(Str, Str)] }` — read/write against an association list.

### Test posture

For each new capability, ship one runtest that exercises the real impl against a tempfile fixture, and one that uses the test impl. The test impls are also what Milestone 14.5's `test_runtime()` should use for the `Config` reader and any log-to-file paths.

### Deferred

Directory walks, file watching, permissions, symlinks. Add as demos demand. Async file I/O is fine as-is — Eio's path APIs already suspend cooperatively.

-----

## Stage 19 — Tests as a top-level form  ⏳ *planned; not yet built*

### Example

```di
test "arithmetic adds" {
    assert (1 + 2) == 3
}

test "stamper exclaims" {
    with [
        Stamper <- ExclaimStamper
    ] @ 'Process {
        assert Stamper.stamp("hi") == "hi!"
    }
}

test "transaction commits on normal exit" {
    let log = TestLogger
    with [
        Logger  <- log
        WriteDb <- TestWriteDb
    ] @ 'Process {
        transfer()                // assume defined in scope
        assert log.contains("COMMIT")
    }
}
```

(A test can also bind a full Wiring with the expression form — `test "name" = with [ ...test_wiring() ] { … }`; see RFC-001 §5.4.)

CLI:
```
$ dilang test path/to/file.di
running 3 tests
  test arithmetic adds ... ok
  test stamper exclaims ... ok
  test transaction commits on normal exit ... ok
3 passed, 0 failed
```

### What's new

`test "name" { body }` as a top-level declaration (alongside `fn`, `capability`, …). `assert expr` and `assert expr, "msg"` (panic on false). `TestLogger`, `FixedClock`, and other deterministic host impls.

### Interpreter changes

AST: `DTest of { name : string; body : expr }`.

CLI: `dilang test file.di` collects all `DTest`s, runs each in a fresh `Eio_main.run` with `Eio_mock.Backend` by default. Each test gets its own ctx; failures (`Panic`, unmatched `assert`) are caught and reported.

Host stdlib additions: `TestLogger` (captures lines in a ref), `FixedClock(instant)`, `TestIO()` (mock backend, deterministic time), `SeqIdGen([list])`. These let the tests deterministically check behaviour.

`assert` is an interpreter intrinsic:

```ocaml
| Call { fn = Var "assert"; args = [cond] } ->
    (match eval ctx cond with
     | VBool true -> VUnit
     | _ -> raise (Panic "assertion failed"))
| Call { fn = Var "assert"; args = [cond; msg] } -> ...
```

### Deferred

`#[test]`-style attributes, test discovery across files, parameterised tests, fixtures (which Dilang explicitly doesn't want — Wiring composition replaces them).

-----

## Future phase — static type checker

Out of scope for the interpreter milestones. The same AST feeds it. It enforces what the interpreter currently trusts:

- Row inference and unification (set-equality, with row variables, syntax §5)
- `pub` exact-row checking (design §3.2.4)
- Capability resolution lexically (design §3.1, §4.1.1)
- Error exhaustiveness (§4.1.4)
- Scope checks (§4.1.3, §4.1.8)
- Lifecycle cycle detection (§4.1.6)
- Forward-reference rejection (§4.1.7)
- Trait bound satisfaction (§4.1.10)
- Impl-private requires resolved at the `with` site (§3.1.4)

The interpreter doesn't get retired by the checker — together they form the front end.

-----

## Cross-cutting: OCaml project sketch

The shape of the codebase after all stages land. Per-stage sections show the *delta* added at each step; this section shows the *destination* — the consolidated types and module signatures the interpreter converges on.

### Core types

```ocaml
(* lib/syntax/ast.ml *)

type ident = string
type type_name = string
type lifetime = string                 (* apostrophe-prefixed scope name, e.g. "'Process" (RFC-001) *)

type literal =
  | LInt    of int64
  | LFloat  of float
  | LStr    of string
  | LBool   of bool
  | LUnit

type expr =
  (* Stage 1–2 *)
  | Lit          of literal
  | Var          of ident
  | Let          of { name : ident; mut : bool; rhs : expr; body : expr }
  | Assign       of { name : ident; rhs : expr }
  | Block        of expr list
  | Call         of { fn : expr; args : expr list }
  | BinOp        of bin_op * expr * expr
  | StringInterp of string_part list
  | Return       of expr
  (* Stage 3–4 *)
  | CapCall      of { cap : ident; method_ : ident; args : expr list }
  | MethodCall   of { recv : expr; name : ident; args : expr list }
  (* RFC-001: `with [ entries ] @ 'Scope { body }` (formerly `Provide`) *)
  | WithCaps     of { entries : with_entry list; scope : lifetime option;
                      body : expr option }
  | StructLit    of { ty : type_name; fields : (ident * expr) list;
                      spread : expr option }
  (* Stage 5 *)
  | If           of expr * expr * expr option
  | Raise        of { variant : ident; payload : expr list }
  | Try          of { body : expr; arms : (pattern * expr) list }
  | NullCoalesce of expr * expr
  (* Stage 5 / DEC-021: short-circuit operators are their own nodes, not BinOp *)
  | And          of expr * expr
  | Or           of expr * expr
  | OptChain     of { recv : expr; name : ident }
  | OptCall      of { recv : expr; name : ident; args : expr list }
  | EnumLit      of { ty : type_name option; tag : string; args : expr list }
  | Match        of expr * (pattern * expr) list
  (* Stage 6 *)
  | Defer        of expr
  (* Stage 7 *)
  | Loop         of expr
  | While        of { cond : expr; body : expr }
  | Break
  | Continue
  (* Stage 8 *)
  | ArrayLit     of expr list
  | Index        of { target : expr; idx : expr }
  | For          of { var : ident; iter : expr; body : expr }
  (* Stage 10 *)
  | Lambda       of { params : (ident * ty option) list; body : expr }
  (* Stage 16 *)
  | Uncancel     of expr
  | Select       of (expr * expr) list
  (* Stage 17 *)
  | Stream       of expr
  | Yield        of expr
  (* Misc *)
  | Panic        of expr
  | Sql          of string_part list

and string_part = SLit of string | SInterp of expr

and with_entry =
  | Binding of { cap : ident; rhs : expr; scope : lifetime option }  (* Cap <- rhs [@ 'Scope] *)
  | Spread  of expr                                                  (* ...wiring_expr *)

and pattern =
  | PWild
  | PVar     of ident
  | PLit     of literal
  | PVariant of { ty : type_name option; tag : string; sub : pattern list }
  | PStruct  of { ty : type_name; fields : (ident * pattern) list }

type decl =
  | DFn     of fn_decl
  | DCap    of cap_decl
  | DTrait  of trait_decl
  | DImpl   of impl_decl
  | DStruct of struct_decl
  | DEnum   of enum_decl
  | DScope  of { name : lifetime; parent : lifetime option }   (* Stage 12: `scope 'X under 'Parent` *)
  | DType   of { name : ident; def : ty }
  | DTest   of { name : string; body : expr }          (* Stage 19 *)

type program = decl list
```

### Runtime values

```ocaml
(* lib/semantics/value.ml *)

type value =
  | VUnit
  | VBool   of bool
  | VInt    of int64
  | VFloat  of float
  | VStr    of string
  | VList   of value list
  | VStruct of { ty : type_name; fields : (string * value ref) list }
  | VEnum   of { ty : type_name; tag : string; payload : value list }
  | VOpt    of value option                  (* Stage 5 *)
  | VArray  of value array ref               (* Stage 8 *)
  | VFn     of fn_value                      (* Stage 10 *)
  | VImpl   of impl_value                    (* Stage 3 *)
  | VHost   of host_value                    (* OCaml-defined built-ins *)
  | VWiring of wiring                        (* Stage 14 *)
  | VStream of stream_handle                 (* Stage 17 *)
  | VFuture of future_handle                 (* Stage 15 *)
  | VGroup  of group_handle                  (* Stage 15 *)
  | VCancel of cancel_token                  (* Stage 16 *)
  | VDur    of float                         (* seconds *)

and fn_value = {
  params  : ident list;
  body    : Ast.expr;
  closure : env;                             (* captured values + caps *)
}

and impl_value = {
  ty            : type_name;
  fields        : (string * value ref) list;
  cap_env       : cap_env;                   (* captured at binding time *)
  methods       : (string * impl_method_dispatch) list;
  drop          : (unit -> unit) option;
  lifecycle     : lifecycle option;          (* Stage 13 *)
}

and impl_method_dispatch =
  | DUser of Ast.impl_method
  | DHost of (ctx -> value list -> value)

and lifecycle = {
  start          : ctx -> unit;
  shutdown       : ctx -> exit_reason -> unit;
  start_requires : ident list;
}

and exit_reason = ExNormal | ExRaised of dilang_error | ExPanicked

and wiring = {
  default_scope        : lifetime;
  entries              : (ident * Ast.expr * lifetime option) list;
  ctx_at_construction  : ctx;
}
```

### Environment and context

```ocaml
(* lib/semantics/env.ml *)

type env = {
  values : (ident * value ref) list;        (* lexical lookup, LIFO *)
  caps   : cap_env;
}

and cap_env = cap_frame list                (* innermost first *)

and cap_frame = {
  scope    : lifetime;                        (* "'Process", "'Request", ... *)
  bindings : (ident * impl_value) list;     (* lexical order; later wins *)
  switch   : Eio.Switch.t;                  (* this frame's switch *)
}

(* lib/runtime/sched.ml *)

type ctx = {
  prog       : Program.tables;
  env        : env;
  defers     : (unit -> unit) list ref;     (* per-activation *)
  sw         : Eio.Switch.t;                (* innermost switch *)
  sw_process : Eio.Switch.t;                (* top-level switch for spawn *)
  stdenv     : Eio_unix.Stdenv.base;
  yield_to   : value Eio.Stream.t option;   (* set inside stream { ... } *)
}
```

### Control-flow exceptions

```ocaml
(* lib/semantics/error.ml *)

exception Return_exn   of value
exception Dilang_error of { tag : string; payload : value list }
exception Cancelled                          (* normalized Eio.Cancel.Cancelled *)
exception Panic        of string
exception Break_exn
exception Continue_exn
```

### Key module signatures

```ocaml
(* lib/syntax/parser.mli *)
val parse_file : string -> Ast.program

(* lib/semantics/resolve.mli *)
val resolve : Ast.program -> Program.tables
(* builds caps/traits/structs/enums/impls indexes, rewrites Call→CapCall
   where the receiver is a declared capability, computes extends-closures *)

(* lib/semantics/eval.mli *)
val eval     : ctx -> Ast.expr -> value
val call_fn  : ctx -> fn_value -> value list -> value
val dispatch : ctx -> impl_value -> string -> value list -> value

(* lib/semantics/lifecycle.mli *)
val eval_with_block :
  ctx -> scope:lifetime option -> entries:Ast.with_entry list ->
  body:Ast.expr -> value

val topo_sort_starts :
  (ident * impl_value) list -> (ident * impl_value) list

(* lib/runtime/stream.mli *)
val spawn_stream : ctx -> Ast.expr -> stream_handle
val take         : stream_handle -> value option

(* lib/stdlib/register.mli *)
val register_constructor : string -> (ctx -> value list -> impl_value) -> unit
val lookup_constructor   : string -> (ctx -> value list -> impl_value) option
val builtin_intrinsics   : (string * (ctx -> value list -> value)) list
(* `print`, `assert`, `panic`, plus Stage-12 `with_cancel` / `with_timeout` etc. *)
```

### The CLI

```ocaml
(* bin/main.ml *)

let () =
  match Sys.argv with
  | [| _; "run"; path |] ->
      Eio_main.run @@ fun env ->
        Eio.Switch.run @@ fun sw ->
          let prog   = Parser.parse_file path in
          let tables = Resolve.resolve prog in
          let ctx    = Sched.make_root ~prog:tables ~sw ~stdenv:env in
          let main_fn = Program.find_main tables in
          ignore (Eval.call_fn ctx main_fn [])

  | [| _; "test"; path |] ->
      let prog   = Parser.parse_file path in
      let tables = Resolve.resolve prog in
      List.iter run_test (Program.tests tables)
      (* each `run_test` opens Eio_mock.Backend.run with a fresh ctx *)

  | _ -> usage ()
```

### Sizing

Rough lines-of-code estimate when all 19 stages are done:

| Area                       | LoC (rough)                  |
|----------------------------|------------------------------|
| AST + parser glue          | 400–600                      |
| Resolve pass               | 200–300                      |
| Eval                       | 800–1200                     |
| Lifecycle + switch wiring  | 200–300                      |
| Stream / defer / cancel    | 200–300                      |
| Host stdlib                | 1500–2000                    |
| Tests                      | 500+ as examples accumulate  |
| **Total**                  | **~4000–5000 OCaml**         |

Most of that lives in the host stdlib, not the interpreter core. The interpreter core is ~2k lines; everything else is "make playground programs runnable" work.

-----

## Cross-cutting: project layout

The originally-sketched layout below was a nested `syntax/semantics/runtime/stdlib`
tree. **What actually landed is a flat `lib/`** (no subdirectories) — the modules
are small enough that nesting earned nothing:

```
dilang-interpreter/                       (* folder at the repo root, alongside dilang-zed/ *)
  dune-project
  dilang.opam
  bin/
    main.ml                               (* CLI entry; thin wrapper over Driver *)
  lib/
    ast.ml                                (* AST; grows with stages *)
    lexer.ml                              (* sedlex lexer *)
    parser.mly                            (* Menhir grammar; parser.conflicts is the conflict budget *)
    eval.ml                               (* the tree walker: eval, call_value, call_impl_method, value_method_dispatch *)
    env.ml                                (* values + cap_env *)
    value.ml                              (* runtime value sum (VImpl, VInt, VEnum, …) *)
    driver.ml                             (* parse → run; run_file ~max_requests *)
    host_builtin.ml                       (* StdoutLogger + Stage-11 HTTP host impls *)
    http_codec.ml                         (* HTTP/1.1 request/response read/write *)
    prelude.ml                            (* always-registered host capabilities/impls *)
    string_util.ml                        (* split-on-substring etc. *)
  test/
    stages/                               (* per-stage .di fixtures *)
    programs/                             (* router/, http_hello/ demos *)
    expect/                               (* per-program expected stdout *)
    run_test.ml                           (* alcotest runner (incl. fork-based HTTP fixture) *)
```

Single dune project. Direct deps: `menhirLib`, `sedlex` (`sedlex.ppx` preprocessor), `eio`, `eio_main`. Dev deps: `alcotest`. Resolve/lifecycle/stream/cancel are not yet separate modules — that work lives in `eval.ml`/`driver.ml` or is unbuilt (Stages 13/16/17).

### Parser choice

**Implemented with Menhir + sedlex** (`lib/parser.mly`, `lib/lexer.ml`). An earlier draft of this plan proposed tree-sitter (`tree-sitter-dilang` via OCaml bindings) as primary with Menhir as the fallback; the project took the fallback. The committed grammar carries a deliberate conflict budget tracked in `lib/parser.conflicts` (currently **14** shift/reduce states, all resolved by default-shift) — `diff` against it on every grammar change.

-----

## Cross-cutting: host stdlib growth

Each stage names the host types it needs. Cumulative table:

| Stage | Host adds                                                                 |
|-------|---------------------------------------------------------------------------|
| 1     | `print`                                                                   |
| 3     | `StdoutLogger`                                                            |
| 7     | (struct lit needs no host; impl is user)                                  |
| 8     | `ExitReason` (enum, registered by resolver)                               |
| 11    | `FiberRuntime`, `TestIO`, `Future`, `Group`, `Mutex`, `Duration`          |
| 12    | `with_cancel`, `with_timeout`, `Cancelled` error, `select`                |
| 13    | `Stream<T>` host type                                                     |
| 14    | `TestLogger`, `FixedClock`, `SeqIdGen`, `assert` intrinsic, mock backend  |

Things explicitly *not* on the critical path: `Postgres`, `HttpClient`, `TokenSigner`. Stub with `panic` until a stage demands them.

-----

## Cross-cutting: out of scope for the interpreter

| Concern                                  | Why deferred                                            |
|------------------------------------------|---------------------------------------------------------|
| Static row checking                      | Type checker phase                                      |
| Scope-escape enforcement                 | Type checker phase                                      |
| `pub` strict-row checking                | Type checker phase                                      |
| Capability resolution at compile time    | Done at runtime via cap-env walk                        |
| Lifecycle cycle detection statically     | Runtime panic in v0                                     |
| Pattern exhaustiveness statically        | Runtime panic in v0                                     |
| Generics monomorphisation                | Values runtime-tagged, generics erased                  |
| Module system                            | Not in spec yet (design §5.1)                           |
| Real `Postgres`/`HttpClient`/JWT impls   | Stubs until needed                                      |
| `Drop` for values inside containers      | Only top-level `let` gets Drop in v0                    |
| Performance                              | Tree-walking, single-domain, no caching                 |
| Multi-file programs / imports            | One file, one program                                   |

-----

## Open questions

1. ~~**Tree-sitter binding ergonomics.**~~ *Resolved:* the interpreter uses **Menhir + sedlex** (`lib/parser.mly`, `lib/lexer.ml`), not tree-sitter. The committed grammar tracks its conflict budget in `lib/parser.conflicts`.
2. **Wiring "same binding set" invariant (DEC-003).** v0 trusts; type checker enforces.
3. **`select` semantics for already-resolved arms.** Syntax §15.4 says "first arm to fire." If a promise is already resolved at select entry, short-circuit without forking. Worth detecting.
4. **`ExitReason.Panicked` vs `ExitReason.Raised`.** Rule: `Panic _ → Panicked`; `Dilang_error _ → Raised(_)`; everything else → `Normal`. Document at the Lifecycle boundary.
5. **`sql"..."` literals.** Parser surfaces as a Sql/StringInterp variant. Host stdlib treats as opaque struct until a backend impl needs them.
6. **Numeric type unification.** `I64`/`U64`/`U32`/`F64` collapse to `VInt`/`VFloat` in v0. The type checker keeps them distinct.
7. **The trait system — design not yet settled.** Traits would be a named interface resolved by *receiver value* (distinct from `capability`, resolved through `with`). The runtime mechanism is already in place (value-method dispatch, DEC-020); the open design questions are surface-level and semantic, not implementation:
   - **Keyword/parser/AST.** No `trait` keyword exists yet; the lexer/parser/eval have no path for it (only `capability`). Inherent impls (DEC-022) cover a type's *own* methods; a trait is the *named, shared* interface form.
   - **Resolution & coherence.** How an `impl Trait for T` is found by receiver, and whether overlapping/orphan impls are allowed. Capabilities sidestep this by being resolved explicitly at the `with` site.
   - **`Self`, default bodies, `extends`.** syntax.md §3 sketches `trait Ord extends Eq`, `Self`-typed params, and default method bodies — none of that is pinned down or implemented.
   - **Bounds vs. rows.** Traits appear as constraints on generic parameters (syntax §8), not in `requires` rows. The interaction with the (also-deferred) row-polymorphic generics is unresolved.
   - **Relationship to capabilities.** Whether `trait` and `capability` stay two constructs or eventually unify. Write a DEC when the shape is chosen; until then, value types use inherent impls.

-----

## First milestone (Stage 1, end-to-end)

Cut a single PR:

- dune project skeleton, opam file, CI hello-world.
- Menhir + sedlex parser wired up; produces AST for the Stage 1 `.di` file.
- Eval implements: `Lit`, `Var`, `Let`, `Block`, `BinOp`, `Call` to the `print` intrinsic.
- CLI: `dilang run stages/01_arith.di` prints `30 / done` and exits 0.
- An `alcotest` suite that compares stdout to an `expect/` file per stage.

That milestone proves: parser produces usable AST, value/env model is correct, eval runs through Eio's main loop. Everything from Stage 2 onward is incremental on top.
