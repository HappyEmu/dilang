# Dilang interpreter — incremental plan

A tree-walking interpreter in OCaml 5 + Eio that grows one concept at a time. Each stage has a small `.di` program demonstrating only the constructs added at that stage. The interpreter must run that program at the end of the stage.

References: design §§1–6, syntax §§1–17, DEC-001..008, examples/01-layered-backend, playground/01..09.

-----

## 0. Why this shape

Dilang has two hard semantic moves: capability rows resolved through lexical `provide` blocks, and suspension without function coloring via the `IO` capability. Tree-walking sidesteps the type-checker problem (defer to a later phase) and Eio's effect-handler scheduler maps the suspension story almost 1:1:

| Dilang construct                         | OCaml/Eio mechanism                                         |
|------------------------------------------|-------------------------------------------------------------|
| Capability stack lookup                  | `cap_env` = list of `cap_frame` walked outside-in           |
| `provide { ... } in { body }`            | Open `Eio.Switch.t`, push frame, run `start`s, eval body    |
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
| 3 | First capability                     | `capability`, `provide ... in ...`, `Cap.method`, `@ Process`        |
| 4 | User impls and composition           | `struct`, `impl X for T`, impl-private `requires`, `extends`, multi-binding `provide` |
| 5 | Errors and Option                    | `enum`, `raise`, `try ... catch`, `Never`, `T?`, `??`, `?.`          |
| 6 | Defer                                | `defer`                                                              |
| 7 | Scopes                               | `scope X`, `@ X` on caps and bindings, `provide @ X`                 |
| 8 | Lifecycle                            | `Lifecycle` impls, `start`/`shutdown`, `ExitReason`, topo order      |
| 9 | Wiring values                        | `provide { ... }` w/o body → `Wiring`, `using w1, w2`, lexical override |
| 10 | Closures and row-polymorphic middleware | `\|...\| ...`, function types, `<R, E>` row variables               |
| 11 | Concurrency via IO                  | `IO.spawn`, `Future`, `Group`, `Mutex`                               |
| 12 | Cancellation                         | `with_cancel`, `Cancelled`, `uncancellable`, `with_timeout`, `select` |
| 13 | Streams and iteration                | `stream { yield }`, `for x in iter`, `loop`, `break`, `continue`     |
| 14 | Tests as a top-level form            | `test "..." { ... }`, `assert`, mock backend                         |

Plus a final non-stage: **future phase**, the static type checker, which consumes the AST and enforces what the interpreter currently trusts.

-----

## Stage 1 — Arithmetic and bindings

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

## Stage 2 — Functions and interpolation

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

## Stage 3 — First capability

### Example

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

### What's new

`capability X { fn m(...) }` declarations, `provide { Cap = impl @ Scope } in { body }`, `Cap.method(args)` dispatch syntax, `@ Process`. `requires {Logger}` is parsed but not enforced at runtime; lookup will fail if it's missing at the call site, with a clearer message than name-resolution would give.

This is the first **real** Dilang program. After this stage the interpreter has the language's core idea working.

### Interpreter changes

AST additions:

```ocaml
type expr =
  | ...
  | CapCall of { cap : ident; method_ : ident; args : expr list }
  | Provide of { entries : provide_entry list; scope : ident option;
                 body : expr option }

and provide_entry =
  | Binding of { cap : ident; rhs : expr; scope : ident }

type decl = ... | DCap of cap_decl

and cap_decl = { name : ident; methods : cap_method list; ... }
```

Name-resolution pass: walk every body, rewrite `Call { fn = Var x; ... }` to `CapCall { cap = x; ... }` when `x` names a declared `capability`. (Bare `Cap.method` syntax is parsed as such directly — see syntax §2.1.)

Env addition:

```ocaml
type cap_frame = {
  scope    : ident;                    (* "Process" *)
  bindings : (ident * impl_value) list;
  switch   : Eio.Switch.t;             (* this frame's switch; mostly for later stages *)
}

type env = { values : ...; caps : cap_frame list }
```

Eval:

```ocaml
| Provide { entries; scope; body = Some b } ->
    Eio.Switch.run @@ fun sw ->
      let scope_name = Option.value scope ~default:"Process" in
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

Constructor registration: a single host-constructor table mapping `"StdoutLogger" -> (args -> impl_value)`. Programs invoking `StdoutLogger()` look up this table.

### Deferred

User-defined impls (Stage 4), capability `extends` (Stage 4), impl-private `requires` (Stage 4), Wiring values (Stage 9), scopes other than `Process` (Stage 7), Lifecycle (Stage 8).

-----

## Stage 4 — User impls and composition

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
    provide {
        Stamper = ExclaimStamper() @ Process
        Greeter = PrefixedGreeter() @ Process
    } in {
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
    provide { WriteDb = EchoDb() @ Process } in { show() }      // binding WriteDb also satisfies ReadDb
}
```

### What's new

`struct T { fields }`, `impl Cap1 [+ Cap2] for T`, impl-private `requires` (a row on the impl block, syntax §4.2), capability `extends` (syntax §2.3), multi-binding `provide` blocks where later bindings can reference earlier ones (syntax §7.1, §4.1.7).

This is the stage where the **cap-env capture pattern** is established — the critical mechanic of Dilang's runtime model:

When evaluating `Greeter = PrefixedGreeter() @ Process`, the impl value records the **capability environment as of that binding point**, which includes the just-added `Stamper` binding. Calls to `Greeter.say(...)` later dispatch into the impl, whose body uses `Stamper.stamp(...)` — and that `Stamper` resolves against the captured environment, not against the caller's environment.

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
- Reject forward references inside a provide block (each binding sees only previous ones).

Eval changes:

- `Provide` block now builds bindings *left to right*, with each binding's RHS evaluated against the frame as it stands so far. The impl value captures `cap_env = current_caps_with_partial_frame`.

```ocaml
let eval_provide_block ctx ~scope ~entries ~body =
  Eio.Switch.run @@ fun sw ->
    let scope_name = Option.value scope ~default:"Process" in
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

Generic impls (Stage 10 via row vars, full generics deferred to type-checker phase), `extends` chains longer than one link (works the same way), trait dispatch on values (`value.method()`) — limited to capability-style for now.

-----

## Stage 5 — Errors and Option

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

`enum E { Variant1; Variant2(payload: T) }`, `raise X(args)`, `try ... catch { Variant -> arm; ... }`, the `Never` type via `raise` and `return`, `Option<T>` with sugar `T?`, `None`/`Some(x)`, `??` (null-coalescing with `Never`-RHS support), `?.` (optional chain/call), `if/else`.

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

## Stage 6 — Defer

### Example

```di
fn handle(name: Str) {
    defer print("cleanup ${name}")
    print("doing ${name}")
}

fn main() {
    handle("a")
    handle("b")

    try {
        defer print("inner cleanup")
        raise BadInput("oops")
    } catch BadInput(_) -> print("caught")
}
```

Expected:
```
doing a
cleanup a
doing b
cleanup b
inner cleanup
caught
```

Note the third block: the defer fires before control reaches the `catch`, because defer is per-function-exit and the `try` doesn't break that activation.

Actually re-reading syntax §14: "defer blocks run on every exit path … LIFO. A defer block runs to completion before exit continues." Defer is **function-scoped** (the enclosing function), not block-scoped. So the third defer is registered in `main`, runs only when `main` exits, not at the `try` boundary. Let me redo the example:

```di
fn risky() raises {AppError} {
    defer print("risky cleanup")
    raise BadInput("oops")
}

fn main() {
    handle("a")
    try risky() catch BadInput(_) -> print("caught")
}
```

Expected:
```
doing a
cleanup a
risky cleanup
caught
```

The `defer` in `risky` runs as `risky` exits via the raise, *before* `main` catches it.

### What's new

`defer expr` registers a finalizer for the enclosing function's exit (normal, raised, cancelled, panicked).

### Interpreter changes

AST: `Defer of expr`.

Eval: `Defer` pushes a closure onto `ctx.defers : (unit -> unit) list ref`. The function-call activation (in `call_fn` and `dispatch_user`) wraps the body in `Fun.protect`:

```ocaml
let call_fn ctx f args =
  let defers = ref [] in
  let activation = { ctx with env = ...; defers } in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun fn -> try fn () with _ -> ()) !defers)
    (fun () ->
      try eval activation f.body with Return_exn v -> v)
```

Defer also runs on `Dilang_error`, `Cancelled` (Stage 12), `Panic`. `Fun.protect`'s `finally` runs on any exit, so this is automatic.

### Deferred

`Drop` for ordinary values (separate hook), defer block ordering across nested function calls (already handled by activations being nested), defer-during-defer (a defer that itself raises is swallowed in v0 — improvement in a later pass).

-----

## Stage 7 — Scopes

### Example

```di
scope Request

capability ReqId @ Request {
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
    provide @ Request {
        ReqId = StaticReqId { id: "abc-123" } @ Request
    } in {
        show_id()
    }

    provide @ Request {
        ReqId = StaticReqId { id: "xyz-789" } @ Request
    } in {
        show_id()
    }
}
```

Expected:
```
request: abc-123
request: xyz-789
```

Each `provide @ Request` creates a fresh frame; the bindings are local to it.

### What's new

`scope X` top-level declaration, `@ X` scope annotation on capability declarations and on bindings, `provide @ X { ... } in { ... }`. Re-entering `provide @ X` per call yields a fresh instance.

### Interpreter changes

AST:

```ocaml
type decl = ... | DScope of ident

type cap_decl = { ...; scopes : ident list }   (* [] = any *)

(* Provide already has `scope : ident option` from Stage 3 *)
```

Eval: nothing fundamentally new — `Provide` already constructs a frame tagged with the scope name (Stage 3 left it as `"Process"` if absent). The scope tag is recorded in the frame; v0 doesn't enforce scope-escape checks (that's the type checker's job).

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

Static enforcement that a `@ Request`-scoped capability isn't bound or used outside a Request scope. v0 lets it slide; the type checker enforces (§4.1.3).

-----

## Stage 8 — Lifecycle

### Example

```di
scope Transaction

capability DbConn @ Transaction {
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
    provide @ Transaction {
        DbConn = PgConn {} @ Transaction
    } in {
        DbConn.execute("UPDATE x SET y = 1")
        // normal exit → COMMIT
    }
}

fn fail() raises {AppError} {
    provide @ Transaction {
        DbConn = PgConn {} @ Transaction
    } in {
        DbConn.execute("UPDATE x SET y = 1")
        raise BadInput("nope")
    }
}

fn main() {
    transfer()
    try fail() catch BadInput(_) -> print("caught")
}
```

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

`Lifecycle` trait — `start()` and `shutdown(exit: ExitReason)`. Detected on impl values when they're bound in a `provide` block. Runs on entry/exit in topological order of `start.requires`, with ties broken by lexical order (design §3.6.3). Started impls roll back in reverse on partial-start failure (§3.6.4).

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

Eval — extend `eval_provide_block`:

```ocaml
let eval_provide_block ctx ~scope ~entries ~body =
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

## Stage 9 — Wiring values

### Example

```di
fn dev_runtime() -> Wiring {
    provide {
        Logger = StdoutLogger() @ Process
    }
}

fn dev_repos() -> Wiring {
    provide {
        Greeter = PrefixedGreeter() @ Process
        Stamper = ExclaimStamper() @ Process
    }
}

fn main() {
    provide {
        using dev_runtime(), dev_repos(),
        Stamper = QuietStamper() @ Process,         // overrides dev_repos's Stamper
    } in {
        Greeter.say("hello")
    }
}
```

Assuming `QuietStamper.stamp(m) -> m`, output is `hello`.

### What's new

`provide { ... }` with no `in` produces a `Wiring` value. `using w1, w2` splats Wirings into the enclosing provide. Lexical order determines override; later wins (syntax §7).

### Interpreter changes

AST already has `Provide { body = None }` and `Using of expr list` from Stage 3 / earlier — we just hadn't given them eval semantics.

Value: `VWiring of wiring`.

```ocaml
type wiring = {
  default_scope : ident;
  entries       : (ident * Ast.expr * ident) list;  (* (cap, rhs, scope) *)
  ctx_at_construction : ctx;
}
```

Eval:

```ocaml
| Provide { entries; scope; body = None } ->
    VWiring {
      default_scope = Option.value scope ~default:"Process";
      entries = entries |> List.filter_map (function
        | Binding { cap; rhs; scope } -> Some (cap, rhs, scope)
        | Using _ -> failwith "using inside Wiring-producing provide isn't legal at v0");
      ctx_at_construction = ctx;
    }
```

In `eval_provide_block`, flatten entries before processing:

```ocaml
let flatten_entries ctx entries =
  List.concat_map (function
    | Binding { cap; rhs; scope } -> [(cap, rhs, scope, ctx)]
    | Using ws ->
        List.concat_map (fun w_expr ->
          match eval ctx w_expr with
          | VWiring w -> List.map (fun (c, r, s) -> (c, r, s, w.ctx_at_construction)) w.entries
          | _ -> panic "using requires a Wiring value")
          ws
  ) entries
```

A spliced binding's RHS is evaluated against the *captured* `ctx_at_construction`, except its `cap_env` is whatever the enclosing provide has built so far (which is the standard rule). The captured ctx supplies value-environment names that the Wiring function referenced.

Lexical override: `built := (cap, impl) :: !built` always appends. Lookup walks the bindings list back-to-front; later entry wins.

### Deferred

Static "same binding set on every call" check (DEC-003) — type-checker phase. v0 trusts the program.

-----

## Stage 10 — Closures and row-polymorphic middleware

### Example

```di
fn with_logging<R, E>(f: fn() -> Unit requires {R} raises {E})
    requires {R, Logger}
    raises {E}
{
    Logger.info("before")
    f()
    Logger.info("after")
}

fn main() {
    provide { Logger = StdoutLogger() @ Process } in {
        with_logging(|| {
            Logger.info("body")
        })
    }
}
```

Expected:
```
before
body
after
```

### What's new

Lambda syntax `|params| body`, function-type syntax with `requires`/`raises` rows, row-variable generics (`<R, E>`).

The closure captures the lexical environment, including the *capability* environment, at creation time. When the inner `Logger.info("body")` runs through `f()`, the `Logger` lookup walks the closure's captured `cap_env`, which is the same one `with_logging` is using — so it works without any row plumbing at runtime.

### Interpreter changes

AST:

```ocaml
type expr = ... | Lambda of { params : ident list; body : expr }

(* fn types are stored on declarations but not used by the eval loop in v0 *)
```

Value:

```ocaml
type value = ... | VFn of fn_value

and fn_value = {
  params  : ident list;
  body    : Ast.expr;
  closure : env;          (* values + caps captured at lambda creation *)
}
```

Eval:

```ocaml
| Lambda { params; body } ->
    VFn { params; body; closure = ctx.env }

| Call { fn; args } ->
    (match eval ctx fn with
     | VFn f ->
         let arg_vs = List.map (eval ctx) args in
         let env' = { f.closure with
                      values = List.combine f.params (List.map ref arg_vs)
                               @ f.closure.values } in
         let defers = ref [] in
         let ctx' = { ctx with env = env'; defers } in
         Fun.protect ~finally:(run_defers defers)
           (fun () -> try eval ctx' f.body with Return_exn v -> v)
     | _ -> panic "not callable")
```

Generic syntax with row variables (`<R, E>`) is parsed and stored on the fn_decl but ignored by the interpreter; rows aren't enforced. The example works because closure capture handles the actual cap routing.

### Deferred

Real row-polymorphic inference and unification (type checker). Trait bounds on generic parameters (e.g., `<T: Ord>`) — parsed, ignored at runtime.

-----

## Stage 11 — Concurrency via IO

### Example

```di
fn main() {
    provide {
        IO = FiberRuntime(workers: 2) @ Process
    } in {
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

Eio threading: every call needs the *current* `Eio.Switch.t`. Until now we've been opening a switch in `Provide` and stashing it in the frame, but we haven't threaded "current switch" through host calls. Add `ctx.sw : Eio.Switch.t` and use the innermost `provide` frame's switch (or, for `IO.spawn`, the `Process` switch since spawned fibers should outlive `Request` scopes).

Host stdlib:

- `FiberRuntime { workers }` constructor — returns an impl_value whose `spawn` calls `Eio.Fiber.fork_promise ~sw:ctx.sw_process`, whose `sleep(d)` calls `Eio.Time.sleep`, etc.
- `Future` — wrapping `Eio.Promise.or_exn`. Trait dispatch on `value.method()` is needed for `f1.await()` syntax. Add minimal trait dispatch: host types declare a methods table; resolution by value's runtime type.
- `Group` — wraps a long-lived `Switch`. `g.concurrent(f)` does `Fiber.fork ~sw:g.switch`. `g.await()` closes the switch.
- `Mutex` — wraps `Eio.Mutex`. (Needed by `InMemoryTaskRepo`-style in-memory repos in tests later.)

`TestIO` constructor backed by `Eio_mock.Backend` is the deterministic alternative — exposed for tests.

### Deferred

`Channel<T>`, signals, networking (`IO.bind/accept`), file system. Add as later examples demand.

-----

## Stage 12 — Cancellation

### Example

```di
fn main() {
    provide { IO = FiberRuntime() @ Process } in {
        try with_timeout(50.millis) {
            IO.sleep(500.millis)
            print("never prints")
        } catch Timeout -> print("timed out")

        let result = IO.with_cancel(|tok| {
            let winner = IO.spawn(|| { IO.sleep(20.millis); "fast" })
            let loser  = IO.spawn(|| { IO.sleep(200.millis); "slow" })
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

`IO.with_cancel(|tok| { ... })`, `tok.trip()`, the `Cancelled` error, `uncancellable { ... }`, `with_timeout(d, action)` (stdlib helper, not a primitive — syntax §15.2). `select { arm; arm }` for racing.

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
          IO.spawn(|| { IO.sleep(d); tok.trip() })
          action()
      })
  }
  ```
  Plus catching `Cancelled` raised from `action` and re-raising as `Timeout` (with a private flag distinguishing timer-trip from external cancel).
- `select` arms are forked into a Switch; each pushes its arm index onto an `Eio.Stream`. The select expression takes the first item and runs the matching arm. Losers keep running (syntax §15.4).

### Deferred

Fine-grained cancellation policy choices, structured concurrency lints. The Eio defaults are good enough.

-----

## Stage 13 — Streams and iteration

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

`stream { ... yield x ... }` produces a `Stream<T>`. `for x in iter { body }` iterates. `loop { ... }` infinite loop. `break`/`continue`. `let mut`-style reassignment (introduced in Stage 1 but exercised here).

### Interpreter changes

AST:

```ocaml
type expr =
  | ...
  | Stream  of expr
  | Yield   of expr
  | Loop    of expr
  | For     of { var : ident; iter : expr; body : expr }
  | Break
  | Continue
  | Assign  of { name : ident; rhs : expr }
```

Value:

```ocaml
type value = ... | VStream of stream_handle

and stream_handle = {
  chan      : value Eio.Stream.t;         (* capacity 0 — rendezvous *)
  producer  : Eio.Fiber.t;                (* cancellable on drop *)
  closed    : bool ref;
}
```

Eval:

```ocaml
exception Break_exn
exception Continue_exn

| Stream body ->
    let chan = Eio.Stream.create 0 in
    let closed = ref false in
    Eio.Fiber.fork ~sw:ctx.sw (fun () ->
      try
        let ctx' = { ctx with yield_to = Some chan } in
        ignore (eval ctx' body);
        closed := true
      with _ -> closed := true);
    VStream { chan; closed; ... }

| Yield e ->
    (match ctx.yield_to with
     | Some chan -> Eio.Stream.add chan (eval ctx e); VUnit
     | None -> panic "yield outside stream")

| For { var; iter; body } ->
    let s = eval ctx iter in
    (match s with
     | VStream sh ->
         let rec loop () =
           if !(sh.closed) then ()
           else
             let v = Eio.Stream.take sh.chan in       (* blocks producer until take *)
             let env' = { ctx.env with values = (var, ref v) :: ctx.env.values } in
             (try eval { ctx with env = env' } body |> ignore
              with Continue_exn -> ());
             loop ()
         in
         (try loop () with Break_exn -> ());
         VUnit
     | _ -> panic "for over non-iterator")

| Loop body ->
    (try while true do ignore (eval ctx body) done with Break_exn -> ()); VUnit

| Break    -> raise Break_exn
| Continue -> raise Continue_exn

| Assign { name; rhs } ->
    let r = List.assoc name ctx.env.values in
    r := eval ctx rhs; VUnit
```

When the consumer `break`s (or its enclosing scope ends), cancel the producer fiber so its `defer`s run.

Iteration for non-Stream iterators (e.g. arrays): in v0, only Streams iterate. Adding `Iterator<T>` trait dispatch and desugaring `for x in iter` to `loop { match iter.next() with Some v -> ... | None -> break }` is a follow-on.

### Deferred

Generic `Iterator<T>` trait dispatch on values, lazy lists, finite arrays as iterators.

-----

## Stage 14 — Tests as a top-level form

### Example

```di
test "arithmetic adds" {
    assert (1 + 2) == 3
}

test "stamper exclaims" {
    provide {
        Stamper = ExclaimStamper() @ Process
    } in {
        assert Stamper.stamp("hi") == "hi!"
    }
}

test "transaction commits on normal exit" {
    let log = TestLogger()
    provide {
        Logger = log              @ Process
        WriteDb = TestWriteDb()   @ Process
    } in {
        transfer()                // assume defined in scope
        assert log.contains("COMMIT")
    }
}
```

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
- Impl-private requires resolved at the `provide` site (§3.1.4)

The interpreter doesn't get retired by the checker — together they form the front end.

-----

## Cross-cutting: project layout

```
dilang-interpreter/                       (* new repo, sibling of dilang-zed *)
  dune-project
  dilang.opam
  bin/
    main.ml                               (* CLI: run / test subcommands *)
  lib/
    syntax/
      ast.ml                              (* grows with stages *)
      ast.mli
      parser.ml                           (* tree-sitter → AST *)
      pretty.ml                           (* debugging printer *)
    semantics/
      env.ml                              (* values + cap_env *)
      value.ml                            (* runtime value sum *)
      error.ml                            (* Dilang_error, Cancelled, Panic *)
      resolve.ml                          (* name resolution, cap-vs-value disambig *)
      lifecycle.ml                        (* topo sort + on_release wiring *)
      eval.ml                             (* the tree walker *)
    runtime/
      sched.ml                            (* ctx, Eio Switch plumbing *)
      stream.ml                           (* stream/yield/for *)
      defer.ml                            (* per-activation defer stack *)
      cancel.ml                           (* Cancellation tokens *)
    stdlib/
      logger.ml                           (* StdoutLogger, JsonLogger, TestLogger *)
      clock.ml                            (* SystemClock, FixedClock *)
      io.ml                               (* FiberRuntime, TestIO *)
      id.ml                               (* UuidV7Gen, SeqIdGen *)
      sync.ml                             (* Mutex *)
      group.ml                            (* Group<R, E> *)
      duration.ml                         (* Duration, 100.millis sugar *)
      register.ml                         (* constructor table *)
  test/
    playground/                           (* link of ../dilang/playground *)
    stages/                               (* the per-stage .di examples in this plan *)
    run_test.ml                           (* alcotest runner *)
    expect/                               (* per-program expected stdout *)
```

Single dune project. Direct deps: `eio_main`, `eio_mock`, `tree-sitter`, `tree-sitter-dilang` (pinned via opam from the sister repo). Dev deps: `alcotest`.

### Parser choice

Use the tree-sitter grammar in `tree-sitter-dilang` via OCaml bindings, converting tree-sitter parse trees to our AST. The grammar is the canonical source; duplicating it in Menhir invites drift. Fallback if tree-sitter integration is rough: Menhir + sedlex, ~600 lines.

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

1. **Tree-sitter binding ergonomics.** The OCaml `tree-sitter` package is thin. If AST translation is tedious, switching to Menhir is a real alternative. Decide after Stage 1.
2. **Wiring "same binding set" invariant (DEC-003).** v0 trusts; type checker enforces.
3. **`select` semantics for already-resolved arms.** Syntax §15.4 says "first arm to fire." If a promise is already resolved at select entry, short-circuit without forking. Worth detecting.
4. **`ExitReason.Panicked` vs `ExitReason.Raised`.** Rule: `Panic _ → Panicked`; `Dilang_error _ → Raised(_)`; everything else → `Normal`. Document at the Lifecycle boundary.
5. **`sql"..."` literals.** Parser surfaces as a Sql/StringInterp variant. Host stdlib treats as opaque struct until a backend impl needs them.
6. **Numeric type unification.** `I64`/`U64`/`U32`/`F64` collapse to `VInt`/`VFloat` in v0. The type checker keeps them distinct.

-----

## First milestone (Stage 1, end-to-end)

Cut a single PR:

- dune project skeleton, opam file, CI hello-world.
- Tree-sitter parser wired up; produces AST for the Stage 1 `.di` file.
- Eval implements: `Lit`, `Var`, `Let`, `Block`, `BinOp`, `Call` to the `print` intrinsic.
- CLI: `dilang run stages/01_arith.di` prints `30 / done` and exits 0.
- An `alcotest` suite that compares stdout to an `expect/` file per stage.

That milestone proves: parser produces usable AST, value/env model is correct, eval runs through Eio's main loop. Everything from Stage 2 onward is incremental on top.
