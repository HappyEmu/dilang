# Syntax tour

A walk through the syntax of every language construct. This is not a formal grammar — it is illustrative. The shapes are intended to be readable rather than precise. As the design iterates, this document will change shape too; pinning a BNF now is premature.

For the *why* behind these shapes, see [design.md](./design.md). For programs that use them in context, see [examples/](./examples/).

> Syntax update: [RFC-001](./rfcs/001-with-scoped-wiring.md) defines scoped capability provisioning as `with [Cap <- expr] @ 'Scope { ... }`, apostrophe-prefixed lifetime scopes, and `...` Wiring spread.

-----

## 1. Functions

### 1.1 Declarations

```di
fn add(a: I64, b: I64) -> I64 {
    a + b
}

pub fn lookup_user(id: Uuid) -> User
    requires {Database, Logger}
    raises   {NotFound}
{
    Database.query(sql"SELECT * FROM users WHERE id = ${id}")
        .first()
        .map(User.from_row)
        ?? raise NotFound
}
```

A function declaration has shape:

```di
[pub] fn name<generics>(params) -> ReturnType
    [requires {...}]
    [raises   {...}]
    [where    bounds]
{ body }
```

The two effect-row clauses are optional and default to `{}`. `pub` is a row-checking modifier (see §3.2.4 of design): declared rows must match the body exactly. Non-`pub` functions infer their rows.

Call sites pass arguments positionally. A named-arguments rule was considered (DEC-010, deferred); revisit alongside the typechecker.

### 1.2 Function types

Function types appear in fields, parameters, and type aliases. The leading `fn` is required.

```di
type Handler = fn(Request) -> Response
    requires {Database, Logger, RequestCtx}
    raises   {}

fn with_logging<R, E>(handler: fn() -> Response requires {R} raises {E}) -> Response
    requires {R, Logger}
    raises   {E}
{ /* ... */ }
```

A function value carries its capability requirements; calling it requires those caps in scope at the call site.

### 1.3 Closures

```di
let add_one = |x| x + 1
let log_and_run = |name, f| { Logger.info(name); f() }
```

Parameter and return types may be annotated explicitly; an annotated closure
spells out its full signature inline:

```di
let mul = |x: I64, y: I64| -> I64 { x * y }
```

Closures infer rows from their bodies. When stored or passed, the inferred rows appear on the function type.

-----

## Operators

### Logical `&&` / `||`

`&&` and `||` short-circuit: the right operand is evaluated only when the left does not already decide the result. Both operands must be `Bool` (see DEC-021).

```di
if req.method == "GET" && req.path.starts_with("/health") { ... }
let ok = cache_hit() || fetch_remote()    // fetch_remote() runs only on a miss
```

Precedence, loosest to tightest: `||`, then `&&`, then `??`, then the comparisons (`==`, `!=`, `<`, `>`, `<=`, `>=`), then `+`/`-`, then `*`/`/`. So `a || b && c` parses as `a || (b && c)`, and `x == y && z` as `(x == y) && z`.

### Calls

A call is `callee(args)`. The callee is usually a name (`foo(x)`, `Some(1)`), but any parenthesised expression that evaluates to a function value can be called directly:

```di
(make_adder(3))(4)        // call the returned closure
(route.handler)(req)      // call a function held in a struct field — see §4
```

-----

## 2. Capabilities

### 2.1 Declarations

```di
capability Logger {
    fn info(msg: Str, fields: Map<Str, Json> = {})
    fn warn(msg: Str, fields: Map<Str, Json> = {})
    fn error(msg: Str, err: Error, fields: Map<Str, Json> = {})

    // Default body — impls inherit if not overridden
    fn debug(msg: Str, fields: Map<Str, Json> = {}) {
        self.info("[DEBUG] ${msg}", fields)
    }
}
```

Shape:

```di
capability Name [@ 'Scope1 | 'Scope2] [extends Other1 + Other2] [where bounds] {
    fn required_method(params) -> Return [raises {...}]
    fn defaulted_method(params) -> Return [raises {...}] { body }
}
```

`self` is implicit in method bodies — it refers to the receiver. It is not declared as a parameter.

### 2.2 Scope annotations

```di
capability Clock @ 'Process { fn now() -> Instant }
capability RequestCtx @ 'Request { fn request_id() -> Uuid }
capability Cache @ 'Process | 'Request { fn get(key: Str) -> Bytes? }
```

No annotation means the capability may be bound in any scope. `@ A | B` means one of the listed scopes.

### 2.3 Composition

```di
capability ReadDb {
    fn query(sql: Sql) -> Rows raises {DbError}
}

capability WriteDb extends ReadDb {
    fn execute(sql: Sql) raises {DbError}
}
```

A `WriteDb` impl satisfies a `ReadDb` requirement.

-----

## 3. Traits

Traits and capabilities share syntactic shape but differ in resolution: traits resolve by receiver value, capabilities resolve through `with` blocks.

```di
trait Iterator<T> {
    fn next() -> T?
    fn close()
}

trait Eq {
    fn eq(other: Self) -> Bool
    fn neq(other: Self) -> Bool { !self.eq(other) }
}

trait Ord extends Eq {
    fn cmp(other: Self) -> Ordering
}
```

Traits cannot appear in `requires` rows; they appear as constraints on generic parameters (see §8).

-----

## 4. Structs and implementations

### 4.1 Structs

Structs are nominal record types. Declared with `struct`:

```di
struct PrefixedLogger { prefix: Str }

struct Cached<T> {
    value: T,
    cached_at: Instant
}

struct UnitMarker {}
```

Instances are constructed with brace literals — fields are always named, never positional. See DEC-009 for the rationale (syntactic split between data construction and function calls):

```di
let logger = PrefixedLogger { prefix: "app" }
let entry  = Cached { value: row, cached_at: Clock.now() }
```

Field order at the literal site is free; the parser matches by name. Every declared field must appear unless it has a default (defaults: future concern).

Fieldless structs may be constructed with the bare name — the empty braces are optional:

```di
let m = UnitMarker          // equivalent to UnitMarker {}
```

This mirrors Rust's unit-struct ergonomics and keeps `with` blocks readable when an impl carries no configuration.

### 4.2 Basic impl shape

```di
impl ReadDb for InMemoryDb {
    fn query(sql: Sql) -> Rows raises {DbError} {
        self.tables.query_in_memory(sql)
    }
}
```

Shape:

```di
impl[<generics>] Cap1 [+ Cap2] for Type[<generics>] [where bounds] {
    [requires {...}]
    fn method(params) -> Return { body }
}
```

An **inherent impl** declares a type's own methods with no capability or trait interface — written `impl Type { ... }` (no `for`). These are the methods that belong to the value itself, reached by receiver (value-method dispatch, DEC-020), never through a `provide` block. See DEC-022.

```di
struct Router { routes: [Route] }

impl Router {
    fn get(prefix: Str, handler: fn(Request) -> Response) -> Router {
        self.routes.push(Route { method: "GET", prefix, handler })
        self                                   // return self → calls chain
    }
    fn dispatch(req: Request) -> Response { /* ... */ }
}

let r = Router { routes: [] }.get("/", hello).get("/time", now)
```

Use an inherent impl when the methods are intrinsic to the type (a `Router`'s `dispatch`); use `impl Cap for Type` when the type is *satisfying a named interface* — a capability bound through `provide`, or (once traits land) a trait resolved by receiver. The two forms compose: a type may have an inherent impl and one or more `impl Cap for Type` blocks; their methods merge (duplicate names across blocks are rejected).

### 4.3 Impl-private requires

An impl may declare a private `requires` row — capabilities it needs internally that callers do not see.

```di
impl ReadDb + WriteDb for Postgres {
    requires {IO, Metrics, Logger}

    fn query(sql: Sql) -> Rows raises {DbError} {
        let _t = Metrics.timer("db.query")
        let conn = self.pool.acquire()
        defer conn.release()
        IO.write(conn.socket, encode_query(sql))
        decode_rows(IO.read(conn.socket))
    }

    fn execute(sql: Sql) raises {DbError} { /* ... */ }
}
```

Callers see `requires {ReadDb}` or `requires {WriteDb}` — not `requires {ReadDb, IO, Metrics}`. The private row is satisfied at the `with` site, not at every call.

### 4.4 Multiple conformance

```di
impl Logger + Metrics for ObservabilityStack { /* ... */ }
```

### 4.5 Generic impls

```di
impl<T> Iterator<T> for Stream<T> { /* ... */ }

impl<K, V> Cache<K, V> for LruCache<K, V>
    where K: Eq + Hash
{ /* ... */ }
```

### 4.6 Calling methods vs. field-held closures

`s.method(args)` always dispatches to a method defined in an `impl` block for the receiver's type — never to a field. A field that *holds* a function value is a separate namespace and is invoked with the parenthesised call form `(s.field)(args)`: `s.field` reads the function value, then `(...)(args)` calls it. This mirrors Rust and means a struct may carry a field and a method of the same name without ambiguity (see DEC-020).

```di
struct Route { handler: fn(Request) -> Response }

impl Describe for Route {
    fn handler() -> Str { "route" }       // a method named `handler`
}

let r = Route { handler: health }
r.handler()        // the impl method → "route"
(r.handler)(req)   // the field-held function, applied to req
```

Value-method calls run with `self` bound to the receiver and the **caller's** capabilities in scope — a struct method that calls a capability resolves it against the `provide` stack active at the call site, not at construction.

-----

## 5. Effect rows

### 5.1 Shape

Rows are sets written `{...}`. Members can be concrete capabilities, row variables, or `+`-extensions.

```di
requires {Database, Logger}                  // two concrete caps
requires {R + Database}                      // row variable R plus Database
requires {R + S}                             // union of two row variables
requires {R + S + Metrics}                   // union of two row variables plus Metrics
```

`+` is associative and commutative. The compiler unifies rows on set equality.

### 5.2 Where rows appear

- Function declarations: `requires {...}` and `raises {...}` clauses after the return type.
- Function types: same clauses inside the type.
- Capability methods: each method has its own optional `raises` row.
- Impl blocks: optional impl-level `requires` row (private to the impl).

-----

## 6. Errors

### 6.1 Raising

```di
raise NotFound
raise BadInput("title is empty")
```

`raise X` is an expression of type `Never` (see §11). It can appear anywhere an expression is expected.

### 6.2 Catching

```di
try fetch_user(id) catch {
    NotFound       -> Response.not_found()
    DbError(e)     -> { Logger.error("db", e); Response.server_error() }
}
```

The catch must be exhaustive over the inner expression's `raises` row, or the outer function must re-declare any uncaught variants.

### 6.3 Re-tagging at boundaries

```di
try Database.query(...) catch DbError(e) -> raise DbFailure(e)
```

No implicit conversion. No `?` operator. The verbosity is intentional (see §2.5.3 of design).

-----

## 7. `with` blocks and Wiring values

### 7.1 Entries

A `with` block contains a comma- or newline-separated list of entries inside `[...]`. Each entry is one of:

- A binding: `Cap <- expr [@ 'Scope]`
- A spread: `...<wiring-expr>`

Entries combine in lexical order; later entries shadow earlier ones on conflict.

### 7.2 Inline bindings only

```di
with [
    Database <- Postgres { url: IO.env("DB_URL") ?? "" }
    Logger   <- JsonLogger
    Clock    <- SystemClock
] @ 'Process {
    serve(8080, router())
}
```

When the `with` expression has `@ 'Scope` after the entry list, bindings without their own `@` default to that scope. If there is no default after the entry list, each direct binding must specify `@ 'Scope`. RHS shapes follow DEC-009: braces for struct literals (`Postgres { url: ... }`), bare name for fieldless structs (`JsonLogger`), parens for function calls returning impl values.

### 7.3 `with` targeting a non-Process scope

```di
with [
    RequestCtx <- fresh_ctx(req)
    Tenant     <- lookup_tenant(req)
] @ 'Request {
    handler()
}
```

### 7.4 Wiring values

A `with [ ... ]` with no body is a value of type `Wiring`.

```di
fn base_runtime() -> Wiring {
    let rt = FiberRuntime { workers: 8 }
    with [
        IO     <- rt           @ 'Process
        Logger <- JsonLogger   @ 'Process
        Clock  <- SystemClock  @ 'Process
    ]
}
```

### 7.5 Composing via spread

```di
with [
    ...base_runtime(), ...pg_repos(),
    TaskRepo <- FailingTaskRepo,       // overrides the one in pg_repos()
] @ 'Process {
    serve(8080, router())
}
```

`...a()` spreads a Wiring into the enclosing block. Bindings and spreads can appear in any order; lexical position determines override precedence. There is no separate `++` operator — composition is a `with`-block construct.

-----

## 8. Generics

### 8.1 Type parameters with trait bounds

```di
fn sort<T: Ord>(xs: List<T>) -> List<T> { /* ... */ }
fn dedup<T: Eq + Hash>(xs: List<T>) -> List<T> { /* ... */ }
```

Capabilities cannot appear as trait bounds — they go in `requires` rows.

### 8.2 Where clauses

```di
fn merge<K, V, M>(a: M, b: M) -> M
    where M: Map<K, V>, K: Eq + Hash
{ /* ... */ }
```

### 8.3 Generic structs, enums, traits, capabilities

```di
struct Cached<T> { value: T, cached_at: Instant }

enum Option<T> {
    Some(T)
    None
}

trait Iterator<T> { fn next() -> T? }

capability Cache<K, V> @ 'Process | 'Request
    where K: Eq + Hash
{
    fn get(key: K) -> V?
    fn put(key: K, val: V)
}
```

### 8.4 Row parameters

Generic parameters that appear only in row positions (`requires {R}`, `raises {E}`) are inferred to be row variables. They cannot carry trait bounds.

```di
type Handler<R> = fn(Request) -> Response requires {R} raises {}

struct Router<R> { /* ... */ }
impl<R> Router<R> {
    fn get<R2>(self, pat: Str, h: Handler<R2>) -> Router<R + R2> { /* ... */ }
}
```

-----

## 9. Scopes

### 9.1 Declaration

```di
scope 'Request under 'Process
scope 'Transaction under 'Process
scope 'HtmlRender under 'Process
```

`Process` is implicit and need not be declared.

### 9.2 Use

A capability annotated `@ 'Request` may only be bound inside `with [...] @ 'Request { ... }`. The compiler rejects use of a `Request`-scoped capability from `Process` scope.

-----

## Arrays

`[T]` is the built-in growable array type. Literals use square brackets; the empty literal `[]` infers its element type from context.

```di
let nums    = [3, 1, 4, 1, 5, 9, 2, 6]
let empty   = []                          // element type inferred at use site
```

Indexed read returns `T`; out-of-bounds reads panic in v0. Indexed assignment writes through an existing slot.

```di
let xs = [10, 20, 30]
print(xs[0])                              // 10
xs[2] = 99
print(xs[2])                              // 99
```

Method dispatch on arrays (value-method form, distinct from capability dispatch):

```di
let xs = [1, 2, 3]
print(xs.len())                           // 3
xs.push(4)
print(xs[3])                              // 4
```

This same value-method dispatch (resolution by the runtime type of the receiver, not through a `provide` block) now also covers user-struct `impl` methods — `point.dist()` calls a method from an `impl … for Point` block — not just the built-in `[T]` and `Str` methods. See §4.6 and DEC-020.

Iteration uses `for x in xs { ... }`. The loop var is immutable per iteration; `break` and `continue` work the same as in `while`. Per DEC-013 `for` is a statement, not an expression — it always evaluates to `()`. Mutating `xs[i] = v` and `xs.push(v)` work in v0 even when `xs` is bound with plain `let`; DEC-015 will eventually require `let mut`.

When the iter expression is a bare name, the closing `{` belongs to the loop body — no struct literal is parsed in the head position:

```di
for n in nums { ... }                      // `nums` is the iter; `{ ... }` is the body
for n in (Source { seed: 0 }) { ... }      // struct lits in the head must be parenthesised
```

The same restriction applies to the head of `if` and `while`.

-----

## 10. Streams and iteration

### 10.1 Stream construction

```di
fn posts_stream(filter: PostFilter) -> Stream<Post>
    requires {PostRepo}
    raises   {DbFailure}
{
    stream {
        let mut page = Page.first()
        loop {
            let batch = try PostRepo.list(page, filter)
                catch DbError(e) -> raise DbFailure(e)
            for post in batch.items { yield post }
            if !batch.has_more { break }
            page = batch.next
        }
    }
}
```

`yield` inside `stream { ... }` suspends until the consumer pulls the next item.

### 10.2 Iteration

```di
for x in some_iterator { process(x) }
```

Desugars to a loop calling `.next()` until it returns `None`. The iterator is dropped (via `Drop`) on loop exit.

-----

## 11. The Never type

`Never` is the bottom type — a subtype of every type. Expressions of type `Never`:

- `return X` — exits the enclosing function.
- `raise X` — raises an error.
- `panic(msg)` — aborts the program.
- Diverging loops (`loop { }` with no break).

This lets early-exit forms compose with operators expecting values:

```di
let user   = RequestCtx.current_user() ?? return Response.unauthorized()
let header = req.header("X-Tenant")    ?? raise BadInput("missing tenant")
```

Functions that never return normally:

```di
fn panic(msg: Str) -> Never { /* abort */ }
fn run_forever() -> Never { loop { do_work() } }
```

-----

## 12. Option and absence

`Option<T>` is a stdlib enum with sugar `T?`.

```di
enum Option<T> { Some(T); None }

let header: Str? = req.header("Authorization")
```

### 12.1 Optional chaining

```di
x?.method(args)        // None if x is None, else Some(x.method(args))
x?.field
chain?.foo()?.bar()    // flat-maps; chains do not nest Option
```

### 12.2 Null coalescing

```di
x ?? fallback              // fallback evaluated only if x is None

let user = lookup() ?? raise NotFound
let port = IO.env("PORT").and_then(parse_int) ?? 8080
```

The right-hand side can have type `Never` (so `?? raise X` and `?? return X` work).

-----

## 13. Bindings and mutation

```di
let x = expr            // immutable binding
let mut x = expr        // mutable binding (reassignable)
```

`mut` is a binding modifier only. There are no `Mut*` types. Whether a method mutates the receiver is not visible in its signature.

-----

## 14. Defer

```di
fn handle_conn(sock: Socket) requires {IO, Logger} {
    defer IO.close(sock)
    defer Logger.info("connection closed")
    // ... use sock ...
}
```

`defer` is **block-scoped**: a deferred expression runs at the end of the smallest enclosing `{ ... }` block, on every exit path from that block — fall-through, `return`, `break`, `continue`, raised error, cancellation, panic. Defers in the same block run in LIFO order (most-recently-registered first). A defer runs to completion before exit continues. See DEC-012.

Each `{ ... }` is its own defer scope: the function body, `if`/`else` branches, `loop`/`while` bodies, `try`/`catch` bodies, `with [...] { ... }` bodies, and bare block expressions all push a fresh frame.

The deferred expression is evaluated when the defer *fires*, not when it is registered (Zig-style; opposite of Go, where defer arguments are captured at the call site). Reads of mutable state inside a defer body see the state as it is at scope exit. To capture a value at registration, bind it to an immutable local first.

What happens when a defer body itself raises, and whether to add `errdefer` (defer that fires only on error exit, à la Zig), are open — see DEC-011.

-----

## 15. Cancellation

### 15.1 with_cancel

```di
IO.with_cancel(|tok| {
    IO.spawn(|| { wait_for_signal(); tok.trip() })
    do_work()
})
```

`tok.trip()` causes any operation currently suspended under this `with_cancel` scope, or any subsequent suspending operation, to raise `Cancelled` at its next suspension point.

### 15.2 with_timeout (stdlib helper)

```di
let response = try with_timeout(2.seconds) {
    HttpClient.get(url)
} catch Timeout -> default_response()
```

Built from `with_cancel` plus a timer that trips the token.

### 15.3 uncancellable

```di
uncancellable {
    transaction.commit()
}
```

Cancellation requested during the block raises only after the block exits.

### 15.4 select

```di
select {
    a.await() -> handle_a()
    b.await() -> handle_b()
    timer.await() -> handle_timeout()
}
```

First arm to fire runs. Others are not implicitly cancelled.

-----

## 16. Lifecycle

```di
impl Lifecycle for Postgres {
    requires {IO, Logger}

    fn start() raises {StartupError} {
        Logger.info("connecting to ${self.url}")
        self.pool = ConnectionPool.connect(self.url)
    }

    fn shutdown(exit: ExitReason) {
        match exit {
            Normal    -> self.pool.drain(timeout: 30.seconds)
            Raised(e) -> { 
                Logger.warn("draining after error"); 
                self.pool.drain(timeout: 10.seconds) 
            }
            Panicked  -> self.pool.close_all()
        }
    }
}
```

`start` runs on entry to the `with` block where the impl is bound, in topological order of `start`-method requires. `shutdown` runs on exit, in reverse order. `ExitReason` distinguishes the exit path.

-----

## 17. Lang-item traits

The compiler knows the following stdlib traits by name and uses them to desugar built-in syntax. Renaming or shadowing them is an error.

| Trait         | Method                            | Built-in syntax                          |
|---------------|-----------------------------------|------------------------------------------|
| `Drop`        | `fn drop()`                       | scope exit cleanup                       |
| `Iterator<T>` | `fn next() -> T?`                 | `for x in iter { ... }`                  |
| `Eq`          | `fn eq(other: Self) -> Bool`      | `==`, `!=`                               |
| `Ord`         | `fn cmp(other: Self) -> Ordering` | `<`, `<=`, `>`, `>=`, sort routines      |
| `Hash`        | `fn hash<H: Hasher>(h: H)`        | `Map<K, V>`, `Set<T>` keying             |
| `Display`     | `fn fmt(w: Writer)`               | `"${x}"` interpolation, `print`          |
| `Clone`       | `fn clone() -> Self`              | explicit duplication                     |
