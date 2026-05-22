# Syntax tour

A walk through the syntax of every language construct. This is not a formal grammar — it is illustrative. The shapes are intended to be readable rather than precise. As the design iterates, this document will change shape too; pinning a BNF now is premature.

For the *why* behind these shapes, see [design.md](./design.md). For programs that use them in context, see [examples/](./examples/).

-----

## 1. Functions

### 1.1 Declarations

```
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

```
[pub] fn name<generics>(params) -> ReturnType
    [requires {...}]
    [raises   {...}]
    [where    bounds]
{ body }
```

The two effect-row clauses are optional and default to `{}`. `pub` is a row-checking modifier (see §3.2.4 of design): declared rows must match the body exactly. Non-`pub` functions infer their rows.

### 1.2 Function types

Function types appear in fields, parameters, and type aliases. The leading `fn` is required.

```
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

```
let add_one = |x| x + 1
let log_and_run = |name, f| { Logger.info(name); f() }
```

Closures infer rows from their bodies. When stored or passed, the inferred rows appear on the function type.

-----

## 2. Capabilities

### 2.1 Declarations

```
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

```
capability Name [@ Scope1 | Scope2] [extends Other1 + Other2] [where bounds] {
    fn required_method(params) -> Return [raises {...}]
    fn defaulted_method(params) -> Return [raises {...}] { body }
}
```

`self` is implicit in method bodies — it refers to the receiver. It is not declared as a parameter.

### 2.2 Scope annotations

```
capability Clock @ Process { fn now() -> Instant }
capability RequestCtx @ Request { fn request_id() -> Uuid }
capability Cache @ Process | Request { fn get(key: Str) -> Bytes? }
```

No annotation means the capability may be bound in any scope. `@ A | B` means one of the listed scopes.

### 2.3 Composition

```
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

Traits and capabilities share syntactic shape but differ in resolution: traits resolve by receiver value, capabilities resolve through `provide` blocks.

```
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

## 4. Implementations

### 4.1 Basic shape

```
impl ReadDb for InMemoryDb {
    fn query(sql: Sql) -> Rows raises {DbError} {
        self.tables.query_in_memory(sql)
    }
}
```

Shape:

```
impl[<generics>] Cap1 [+ Cap2] for Type[<generics>] [where bounds] {
    [requires {...}]
    fn method(params) -> Return { body }
}
```

### 4.2 Impl-private requires

An impl may declare a private `requires` row — capabilities it needs internally that callers do not see.

```
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

Callers see `requires {ReadDb}` or `requires {WriteDb}` — not `requires {ReadDb, IO, Metrics}`. The private row is satisfied at the `provide` site, not at every call.

### 4.3 Multiple conformance

```
impl Logger + Metrics for ObservabilityStack { /* ... */ }
```

### 4.4 Generic impls

```
impl<T> Iterator<T> for Stream<T> { /* ... */ }

impl<K, V> Cache<K, V> for LruCache<K, V>
    where K: Eq + Hash
{ /* ... */ }
```

-----

## 5. Effect rows

### 5.1 Shape

Rows are sets written `{...}`. Members can be concrete capabilities, row variables, or `+`-extensions.

```
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

```
raise NotFound
raise BadInput("title is empty")
```

`raise X` is an expression of type `Never` (see §11). It can appear anywhere an expression is expected.

### 6.2 Catching

```
try fetch_user(id) catch {
    NotFound       -> Response.not_found()
    DbError(e)     -> { Logger.error("db", e); Response.server_error() }
}
```

The catch must be exhaustive over the inner expression's `raises` row, or the outer function must re-declare any uncaught variants.

### 6.3 Re-tagging at boundaries

```
try Database.query(...) catch DbError(e) -> raise DbFailure(e)
```

No implicit conversion. No `?` operator. The verbosity is intentional (see §2.5.3 of design).

-----

## 7. Provide blocks and Wiring values

### 7.1 Entries

A `provide` block contains a comma- or newline-separated list of entries. Each entry is one of:

- A binding: `Cap = expr @ Scope`
- A splat: `using <wiring-expr>[, <wiring-expr>...]`

Entries combine in lexical order; later entries shadow earlier ones on conflict.

### 7.2 Inline bindings only

```
provide {
    Database = Postgres(IO.env("DB_URL") ?? "") @ Process
    Logger   = JsonLogger()                     @ Process
    Clock    = SystemClock()                    @ Process
} in {
    serve(8080, router())
}
```

Every binding specifies its scope with `@ ScopeName`. No defaults.

### 7.3 Provide targeting a non-Process scope

```
provide @ Request {
    RequestCtx = fresh_ctx(req) @ Request
    Tenant     = lookup_tenant(req) @ Request
} in {
    handler()
}
```

### 7.4 Wiring values

A `provide { ... }` with no `in` is a value of type `Wiring`.

```
fn base_runtime() -> Wiring {
    let rt = FiberRuntime(workers: 8)
    provide {
        IO     = rt              @ Process
        Logger = JsonLogger()    @ Process
        Clock  = SystemClock()   @ Process
    }
}
```

### 7.5 Composing via `using`

```
provide {
    using base_runtime(), pg_repos(),
    TaskRepo = FailingTaskRepo() @ Process,     // overrides the one in pg_repos()
} in {
    serve(8080, router())
}
```

`using a(), b()` splats one or more Wirings into the enclosing block. Bindings and `using` directives can appear in any order; lexical position determines override precedence. There is no separate `++` or `with` operator — composition is a `provide`-block construct.

-----

## 8. Generics

### 8.1 Type parameters with trait bounds

```
fn sort<T: Ord>(xs: List<T>) -> List<T> { /* ... */ }
fn dedup<T: Eq + Hash>(xs: List<T>) -> List<T> { /* ... */ }
```

Capabilities cannot appear as trait bounds — they go in `requires` rows.

### 8.2 Where clauses

```
fn merge<K, V, M>(a: M, b: M) -> M
    where M: Map<K, V>, K: Eq + Hash
{ /* ... */ }
```

### 8.3 Generic structs, enums, traits, capabilities

```
struct Cached<T> { value: T, cached_at: Instant }

enum Option<T> {
    Some(T)
    None
}

trait Iterator<T> { fn next() -> T? }

capability Cache<K, V> @ Process | Request
    where K: Eq + Hash
{
    fn get(key: K) -> V?
    fn put(key: K, val: V)
}
```

### 8.4 Row parameters

Generic parameters that appear only in row positions (`requires {R}`, `raises {E}`) are inferred to be row variables. They cannot carry trait bounds.

```
type Handler<R> = fn(Request) -> Response requires {R} raises {}

struct Router<R> { /* ... */ }
impl<R> Router<R> {
    fn get<R2>(self, pat: Str, h: Handler<R2>) -> Router<R + R2> { /* ... */ }
}
```

-----

## 9. Scopes

### 9.1 Declaration

```
scope Request
scope Transaction
scope HtmlRender
```

`Process` is implicit and need not be declared.

### 9.2 Use

A capability annotated `@ Request` may only be bound inside `provide @ Request { ... }`. The compiler rejects use of a `Request`-scoped capability from `Process` scope.

-----

## 10. Streams and iteration

### 10.1 Stream construction

```
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

```
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

```
let user   = RequestCtx.current_user() ?? return Response.unauthorized()
let header = req.header("X-Tenant")    ?? raise BadInput("missing tenant")
```

Functions that never return normally:

```
fn panic(msg: Str) -> Never { /* abort */ }
fn run_forever() -> Never { loop { do_work() } }
```

-----

## 12. Option and absence

`Option<T>` is a stdlib enum with sugar `T?`.

```
enum Option<T> { Some(T); None }

let header: Str? = req.header("Authorization")
```

### 12.1 Optional chaining

```
x?.method(args)        // None if x is None, else Some(x.method(args))
x?.field
chain?.foo()?.bar()    // flat-maps; chains do not nest Option
```

### 12.2 Null coalescing

```
x ?? fallback              // fallback evaluated only if x is None

let user = lookup() ?? raise NotFound
let port = IO.env("PORT").and_then(parse_int) ?? 8080
```

The right-hand side can have type `Never` (so `?? raise X` and `?? return X` work).

-----

## 13. Bindings and mutation

```
let x = expr            // immutable binding
let mut x = expr        // mutable binding (reassignable)
```

`mut` is a binding modifier only. There are no `Mut*` types. Whether a method mutates the receiver is not visible in its signature.

-----

## 14. Defer

```
fn handle_conn(sock: Socket) requires {IO, Logger} {
    defer IO.close(sock)
    defer Logger.info("connection closed")
    // ... use sock ...
}
```

`defer` blocks run on every exit path: normal return, raised error, cancellation, panic. They run in LIFO order. A defer block runs to completion before exit continues.

-----

## 15. Cancellation

### 15.1 with_cancel

```
IO.with_cancel(|tok| {
    IO.spawn(|| { wait_for_signal(); tok.trip() })
    do_work()
})
```

`tok.trip()` causes any operation currently suspended under this `with_cancel` scope, or any subsequent suspending operation, to raise `Cancelled` at its next suspension point.

### 15.2 with_timeout (stdlib helper)

```
try with_timeout(2.seconds) {
    HttpClient.get(url)
} catch Timeout -> default_response()
```

Built from `with_cancel` plus a timer that trips the token.

### 15.3 uncancellable

```
uncancellable {
    transaction.commit()
}
```

Cancellation requested during the block raises only after the block exits.

### 15.4 select

```
select {
    a.await() -> handle_a()
    b.await() -> handle_b()
    timer.await() -> handle_timeout()
}
```

First arm to fire runs. Others are not implicitly cancelled.

-----

## 16. Lifecycle

```
impl Lifecycle for Postgres {
    requires {IO, Logger}

    fn start() raises {StartupError} {
        Logger.info("connecting to ${self.url}")
        self.pool = ConnectionPool.connect(self.url)
    }

    fn shutdown(exit: ExitReason) {
        match exit {
            Normal    -> self.pool.drain(timeout: 30.seconds)
            Raised(e) -> { Logger.warn("draining after error"); self.pool.drain(timeout: 10.seconds) }
            Panicked  -> self.pool.close_all()
        }
    }
}
```

`start` runs on entry to the `provide` block where the impl is bound, in topological order of `start`-method requires. `shutdown` runs on exit, in reverse order. `ExitReason` distinguishes the exit path.

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
