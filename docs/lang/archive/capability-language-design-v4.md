# Capability-Native Language: Design Document v4

A programming language with dependency injection as a first-class language feature, checked at compile time. Dependencies are tracked through the type system as **capability rows** that flow through function signatures and are satisfied by lexically-scoped `provide` blocks. The runtime — task scheduling, cancellation, sleep, file I/O, networking, standard streams, signal handling, subprocesses, entropy, and sync primitives — is exposed as a decomposed collection of capabilities under the `io.*` naming convention rather than a single monolithic type. User code reads as synchronous; the choice of impls at `main` determines actual execution semantics.

This is v4. It supersedes v3 in the areas listed in section 9. Earlier versions remain useful only as historical reference; v4 is the canonical specification.

-----

## 1. Motivation

Existing DI approaches fall into three camps, each with problems:

- **Annotation + container** (Spring, Dagger, .NET DI): runtime resolution, bolted onto the language, errors surface late.
- **Implicits / context parameters** (Scala 3, Kotlin 2.2): compile-time but retrofitted into a non-DI language, with limitations around composition and lifetime management.
- **Algebraic effects** (Koka, Effekt): powerful and principled, but require deep familiarity with effect systems.

Existing concurrency approaches also fall short:

- **Colored async** (Rust, JS, Python, C#): `async`/`await` infects function signatures, splits the ecosystem into sync/async universes, and forces two parallel standard libraries.
- **Runtime-managed fibers** (Go, BEAM, JVM virtual threads, Zig 0.16's `std.Io`): no function coloring at the signature level, but bundling unrelated platform concerns (file I/O, stdout, signal handling, executor, network, sync, entropy) into one runtime interface means impls overclaim what they depend on, browser/embedded targets must lie about absent capabilities, and tests must stub the full surface.

v4 unifies both concerns. The runtime appears as twelve independent capabilities (`io.Tasks`, `io.Clock`, `io.Sleep`, `io.NetClient`, `io.NetServer`, `io.FileSystem`, `io.MemoryMap`, `io.Stdio`, `io.Signals`, `io.Process`, `io.Entropy`, `io.Sync`); IO-performing capability implementations declare exactly the runtime surface they need (privately, not visible to callers). User code reads as synchronous; the impls chosen at `main` determine whether calls block, suspend fibers, run on an event loop, or execute synchronously in tests. Cancellation is a first-class primitive (`with_cancel` returning a `CancelToken`); timeouts derive from it.

Four coupled features:

1. **Capabilities** — interfaces resolved lexically via `provide` blocks, used for dependencies.
1. **Traits** — interfaces resolved by receiver value, used for shape and behavior.
1. **Effect rows** — sets of capabilities a function needs (`requires`) and errors it can raise (`raises`), tracked in function signatures.
1. **`provide` blocks and `Wiring` values** — lexical wiring points that bind capabilities to implementations, parameterized by named `scope`s.

The result: missing dependencies, scope mismatches, unhandled errors, missing runtime services, and out-of-scope capability uses are all compile errors; the runtime is a deployment choice; tests use the same wiring mechanism as production.

-----

## 2. Core concepts

### 2.1 Capabilities and traits

The language has two distinct interface mechanisms. They share syntactic shape but serve different roles.

**Capabilities** are resolved lexically through `provide` blocks. Methods are called as `Cap.method(args)` — the capability name itself names the binding. Capabilities appear in `requires` rows on function signatures, are bound to scopes, and participate in lifecycle. They model dependencies.

```
capability Logger {
    fn info(msg: Str, fields: Map<Str, Json> = {})
    fn warn(msg: Str, fields: Map<Str, Json> = {})
    fn error(msg: Str, err: Error, fields: Map<Str, Json> = {})

    // Default body — see 2.13
    fn debug(msg: Str, fields: Map<Str, Json> = {}) {
        self.info("[DEBUG] ${msg}", fields)
    }
}

capability Clock @ Process {
    fn now() -> Instant
    fn monotonic() -> Duration
}

capability RequestCtx @ Request {
    fn request_id() -> Uuid
    fn current_user() -> User?
}
```

**Traits** are resolved by the receiver value. Methods are called as `value.method(args)`. Traits do not appear in `requires` rows; they constrain generic type parameters via bounds (`<T: Eq>`). They model shape — what a value can do.

```
trait Iterator<T> {
    fn next() -> T?
    fn close()

    fn map<U>(f: fn(T) -> U) -> MappedIterator<T, U, Self> {
        MappedIterator { inner: self, f }
    }
}

trait Eq {
    fn eq(other: Self) -> Bool
    fn neq(other: Self) -> Bool { !self.eq(other) }
}
```

**Heuristic for choosing between them.** If a function would say `requires {X}` to use `X`, declare `X` a capability. If a function would say `x: X` to take a value of `X`, declare `X` a trait. Capabilities are dependencies you pull from scope; traits are shapes values have.

`self` is implicit in both capability and trait method bodies — it refers to the receiver value. It is not declared as a parameter.

**Scope annotations on capabilities:**

- No annotation — the capability can be bound in any scope at the `provide` site.
- `@ ScopeName` — restricted to that scope.
- `@ A | B` — restricted to one of the listed scopes.

`Process` is the implicit root scope. User-declared scopes (`scope Request`, `scope Transaction`, etc.) are described in 2.11.

**Composition via `extends`** works for both capabilities and traits:

```
capability ReadDb {
    fn query(sql: Sql) -> Rows raises {DbError}
}

capability WriteDb extends ReadDb {
    fn execute(sql: Sql) -> Unit raises {DbError}
    fn transaction<R, E>(block: fn() -> R requires {WriteDb} raises {E}) -> R
        raises {E, DbError}
}

trait Ord extends Eq {
    fn cmp(other: Self) -> Ordering
}
```

A function requiring `{ReadDb}` is satisfied by any impl of `WriteDb`. A generic with bound `T: Ord` requires `T` to implement both `Ord` and `Eq`.

### 2.2 Implementations

Trait-style: `impl X for Type`, where `X` is a capability or a trait. Multiple conformances combine with `+` in a single block.

Implementations may declare an **impl-level `requires` row** for capabilities they need internally. These are private — they're satisfied when the impl is constructed inside a `provide` block where the needed caps are in scope, and they do **not** propagate to callers of the impl's methods.

```
// Postgres talks to a socket: needs io.NetClient. Hidden from callers.
impl ReadDb + WriteDb for Postgres {
    requires {io.NetClient, Metrics, Logger}

    fn query(sql: Sql) -> Rows raises {DbError} {
        let _t = Metrics.timer("db.query")
        let conn = self.pool.acquire()
        defer conn.release()
        io.NetClient.write(conn.socket, encode_query(sql))
        decode_rows(io.NetClient.read(conn.socket))
    }
    fn execute(sql: Sql) -> Unit raises {DbError} { /* ... */ }
    fn transaction<R, E>(block: fn() -> R requires {WriteDb} raises {E}) -> R
        raises {E, DbError} { /* ... */ }
}

// A pure in-memory impl needs nothing.
impl ReadDb for InMemoryDb {
    fn query(sql: Sql) -> Rows raises {DbError} {
        self.tables.query_in_memory(sql)
    }
}

// JsonLogger declares exactly what it touches: stdout. Not the whole runtime.
impl Logger for JsonLogger {
    requires {io.Stdio}

    fn info(msg: Str, fields: Map<Str, Json>) {
        io.Stdio.stdout(json_encode({"level": "info", "msg": msg, ...fields}))
    }
    fn warn(msg: Str, fields: Map<Str, Json>) { /* ... */ }
    fn error(msg: Str, err: Error, fields: Map<Str, Json>) { /* ... */ }
}
```

**Generic impls** use the same generic-parameter syntax as functions (see 2.14):

```
impl<T> Iterator<T> for Stream<T> {
    fn next() -> T? { /* ... */ }
    fn close() { /* ... */ }
}

impl<K, V> Cache<K, V> for LruCache<K, V>
    where K: Eq + Hash
{
    fn get(key: K) -> V? { /* ... */ }
    fn put(key: K, val: V) { /* ... */ }
}
```

The caller of `ReadDb.query(...)` writes the same code whether the impl is `Postgres` (using `io.NetClient` to drive a socket) or `InMemoryDb` (no I/O at all). The caller's signature shows `requires {ReadDb}`, not `requires {ReadDb, io.NetClient}`.

### 2.3 Effect rows on functions

Every function signature has two optional effect clauses, in fixed order:

```
[pub] fn name<generics>(params) -> ReturnType
    requires {...}
    raises   {...}
    [where   bounds]
{ body }
```

|Clause             |Meaning                                 |Default if omitted|
|-------------------|----------------------------------------|------------------|
|`requires {C1, C2}`|Capabilities the function needs in scope|`{}`              |
|`raises {E1, E2}`  |Errors the function can `raise`         |`{}`              |

**Row syntax:** commas separate concrete elements inside `{}`. `+` extends a row with additional members, where the left-hand side may be a row variable, a concrete cap, or another `+`-expression:

```
requires {R + Database, Logger}       // row variable R, plus Database and Logger
requires {R + S}                      // union of two row variables
requires {R + S + Metrics}            // union of two row variables plus Metrics
```

The `+` operator is associative and commutative on rows; the compiler unifies on row equivalence (set equality up to order). Row-variable composition (`R + S`) is what allows generic types like `Router<R>` (see 4.x) to accumulate rows from heterogeneous handlers.

### 2.4 Row inference and `pub`

`pub` is a modifier on function declarations that controls API contract enforcement. It is **not** a visibility modifier in v4 (no module system exists; see section 8). It applies only to functions.

- **`pub fn`**: `requires` and `raises` rows must be declared explicitly. The compiler verifies the declared row matches the body's inferred row exactly. Over-declaration (listing a capability or error the body does not use) is an error, not a warning.
- **Non-`pub fn`**: rows are inferred from the body. An explicit declaration is permitted but must agree with the inferred set.

Capability methods, trait methods, and entry points (`main`) are treated as `pub` regardless of explicit marking. Empty rows on `main` may be elided.

This catches "silently added a dependency to the public API" at the boundary while keeping internal refactors frictionless.

### 2.5 Function types

Function types use `fn(Args) -> Return` syntax everywhere. The leading `fn` is required even for nullary functions.

```
type Handler = fn(Request) -> Response
    requires {Database, Logger, RequestCtx}
    raises   {}

let h: Handler = get_tasks
router.get("/tasks", h)

// Higher-order: closure parameters use the same syntax
fn with_logging<R, E>(handler: fn() -> Response requires {R} raises {E}) -> Response
    requires {R, Logger}
    raises   {E}
{ /* ... */ }
```

Effect rows appear in function types as well as declarations. A function value carries its capability requirements with it; calling the value requires those caps in scope.

### 2.6 The `io.*` capabilities

The stdlib provides twelve runtime capabilities under the `io.*` naming convention. The dot is part of the capability name; there is no `module` keyword in v4 (deferred — see section 8).

The capabilities are **independent**: a target may provide some and not others. Code declares the minimal slice it actually touches.

#### 2.6.1 Scheduler — `io.Tasks`

```
capability io.Tasks @ Process {
    fn async<R, E, Rq>(task: fn() -> R requires {Rq} raises {E}) -> Future<R, E>
        requires {Rq}
    fn concurrent<R, E, Rq>(task: fn() -> R requires {Rq} raises {E}) -> Future<R, E>
        requires {Rq}
    fn yield_now()
    fn with_cancel<R>(action: fn(CancelToken) -> R) -> R
}
```

`async` permits but does not require concurrent execution — a `SyncTasks` impl is free to run the task to completion inside the `async` call and return an already-resolved `Future`. `concurrent` is a hard requirement of overlap; impls that cannot honor it raise `StartupError` at construction or `ConcurrencyUnavailable` at the call site, depending on whether the limitation is known at wiring time.

The distinction matters for portability. Test runtimes can implement `async` trivially; libraries that internally need true overlap (e.g., a request multiplexer) must use `concurrent` and accept the narrower compatibility envelope.

#### 2.6.2 Futures, groups, and select

`Future<R, E>` and `Group<R, E>` are stdlib value types, not capabilities. Both carry internal references to `io.Tasks` and surface that requirement on each method.

```
struct Future<R, E> { /* opaque */ }

impl<R, E> Future<R, E> {
    fn await()  -> R requires {io.Tasks} raises {E, Cancelled}
    fn cancel() -> R requires {io.Tasks} raises {E, Cancelled}
}

struct Group<R, E> { /* opaque */ }

impl<R, E> Group<R, E> {
    fn new() -> Group<R, E>
    fn concurrent<Rq>(task: fn() -> R requires {Rq} raises {E})
        requires {Rq, io.Tasks}
    fn async<Rq>(task: fn() -> R requires {Rq} raises {E})
        requires {Rq, io.Tasks}
    fn await()  raises {E, Cancelled} requires {io.Tasks}
    fn cancel() raises {E, Cancelled} requires {io.Tasks}
}
```

`Future.cancel` is equivalent to `await` except it also requests interruption: the task is signaled, the next suspending operation it performs raises `Cancelled`, and `cancel` returns when the task has finished unwinding. This is *trip-and-wait* semantics on the join side.

`Group.cancel` propagates cancellation to all members and returns when the last has finished. If any member ended in `Cancelled` or any other variant of `E`, `cancel` raises that. This is the drain-then-fail behavior real servers need on shutdown.

`select` is stdlib syntax over a finite set of awaitable expressions:

```
select {
    a.await() -> handle_a(...)
    b.await() -> handle_b(...)
    timer.await() -> handle_timeout()
}
```

The first arm to become ready runs; the others are *not* cancelled implicitly (callers can `.cancel()` them in the arm body if desired). `select` requires `{io.Tasks}` in scope.

#### 2.6.3 Cancellation primitive

```
struct CancelToken { /* opaque */ }

impl CancelToken {
    fn trip()              // returns immediately; targeted ops raise Cancelled
    fn tripped() -> Bool
}
```

`io.Tasks.with_cancel(action)` runs `action` with a fresh `CancelToken` in scope. Calling `token.trip()` from any context (typically a sibling task, a signal handler, or a timer) sets the cancellation flag. Any blocking operation performed by the action inside the `with_cancel` block then raises `Cancelled` at its next suspension point. See §2.7 for the full cancellation semantics, including timeouts as a derived form.

#### 2.6.4 Time — `io.Clock` and `io.Sleep`

```
capability io.Clock @ Process {
    fn now() -> Instant
    fn monotonic() -> Duration
}

capability io.Sleep @ Process {
    fn sleep(d: Duration) raises {Cancelled}
    fn remaining() -> Duration?    // residual under enclosing with_timeout
}
```

Split deliberately. `FixedClock` lets tests read wall time without affecting scheduling. `SkipSleep` advances simulated time without blocking. Pure computation that timestamps results needs `io.Clock` but not `io.Sleep`.

#### 2.6.5 Networking — `io.NetClient` and `io.NetServer`

```
capability io.NetClient @ Process {
    fn connect(addr: SocketAddr) -> Socket raises {IoError, Cancelled}
    fn read(s: Socket, buf: Bytes)  -> I64 raises {IoError, Cancelled}
    fn write(s: Socket, buf: Bytes) -> I64 raises {IoError, Cancelled}
    fn close(s: Socket)
}

capability io.NetServer @ Process {
    fn bind(addr: SocketAddr) -> Listener raises {IoError}
    fn accept(l: Listener) -> Socket raises {IoError, Cancelled}
    fn close(l: Listener)
}
```

Same `Socket` value type; one capability dials, the other listens. An impl that provides both shares the underlying poller. Edge targets typically ship `NetClient` only.

The constraint "a fiber-runtime impl must use non-blocking sockets internally" applies to the *impl*, not the capability boundary. Calling code requires `{io.NetClient}` whether the impl is `BlockingNet` (one OS thread per socket) or `UringNet` (fiber-aware, parking on `IORING_OP_RECV` CQEs).

#### 2.6.6 Filesystem — `io.FileSystem` and `io.MemoryMap`

```
capability io.FileSystem @ Process {
    fn open(path: Path, mode: OpenMode) -> FileDesc raises {IoError}
    fn read(fd: FileDesc, buf: Bytes)  -> I64 raises {IoError, Cancelled}
    fn write(fd: FileDesc, buf: Bytes) -> I64 raises {IoError, Cancelled}
    fn close(fd: FileDesc)
    fn stat(path: Path) -> Stat raises {IoError}
    fn mkdir(path: Path) raises {IoError}
    fn readdir(path: Path) -> Stream<DirEntry> raises {IoError}
    fn rename(from: Path, to: Path) raises {IoError}
    fn remove(path: Path) raises {IoError}
}

capability io.MemoryMap @ Process {
    fn map(fd: FileDesc, range: Range) -> MappedRegion raises {IoError}
    fn unmap(r: MappedRegion)
}
```

mmap is split out because it requires VM control that WASM, edge, and many embedded targets cannot provide, and the code that uses it (databases, indexes, zero-copy parsers) is structurally distinct from stream I/O.

#### 2.6.7 Standard streams — `io.Stdio`

```
capability io.Stdio @ Process {
    fn stdout(buf: Bytes)
    fn stderr(buf: Bytes)
    fn stdin(buf: Bytes) -> I64 raises {IoError, Cancelled}
}
```

stdin returns the number of bytes read into the provided buffer. Closed-stream conditions are represented by a zero return, mirroring POSIX `read`.

#### 2.6.8 Signals — `io.Signals`

```
capability io.Signals @ Process {
    fn wait_for(signals: List<Signal>) -> Signal raises {Cancelled}
}
```

#### 2.6.9 Process — `io.Process`

```
capability io.Process @ Process {
    fn spawn_child(cmd: Command) -> ChildProcess raises {IoError}
    fn env(name: Str) -> Str?
    fn env_all() -> Map<Str, Str>
    fn args() -> List<Str>
    fn exit(code: I32) -> Never
}
```

Environment access and process arguments are explicit capability calls. Code that reads configuration declares `requires {io.Process}`, which makes the production-vs-test config swap a `provide` swap rather than a global-state hack. There is no implicit global `env` accessor in v4.

#### 2.6.10 Entropy — `io.Entropy`

```
capability io.Entropy @ Process {
    fn fill(buf: Bytes)
    fn u64() -> U64
}
```

Crypto libraries, ID generators, and jittered backoff strategies declare `requires {io.Entropy}` instead of reading `/dev/urandom` or calling architecture intrinsics. Tests bind `SeededRng(seed)` for determinism; production binds `KernelRng()`.

#### 2.6.11 Sync primitives — `io.Sync`

Sync primitives must be runtime-aware: a fiber mutex must park fibers, a thread mutex must park OS threads, a single-threaded test impl can implement everything trivially. v4 exposes them as a **factory capability** that produces stdlib value types.

```
capability io.Sync @ Process {
    fn new_mutex<T>(initial: T) -> Mutex<T>
    fn new_condvar() -> Condvar
    fn new_channel<T>(capacity: USize) -> Channel<T>
    fn new_semaphore(permits: USize) -> Semaphore
}

struct Mutex<T> { /* opaque, holds runtime reference */ }

impl<T> Mutex<T> {
    fn lock<R>(action: fn(T) -> R) -> R requires {io.Sync}
}

struct Channel<T> { /* opaque */ }

impl<T> Channel<T> {
    fn send(value: T)         requires {io.Sync} raises {Cancelled, Closed}
    fn recv() -> T            requires {io.Sync} raises {Cancelled, Closed}
    fn try_send(value: T) -> Bool
    fn try_recv() -> T?
    fn close()
}

struct Semaphore { /* opaque */ }

impl Semaphore {
    fn acquire() requires {io.Sync} raises {Cancelled}
    fn release()
}
```

The returned values hold hidden references to the scheduler underneath the `io.Sync` impl. The type system does not expose this, but it is why `Mutex.lock` can park fibers under a fiber runtime and OS threads under a threaded runtime without callers knowing which. The closure form on `lock` makes unlock exception-safe by construction — there is no `defer mutex.unlock()` discipline to remember.

A `SingleThread` impl for tests returns trivial primitives: `Mutex.lock` is just running the closure; `Channel` is a queue with no scheduling logic.

#### 2.6.12 Picking impls at `main`

The choice of impls at `main` is the choice of runtime. A single impl may conform to multiple capabilities; bindings are listed per-capability.

```
// Production server, full surface
let rt = FiberRuntime(workers: 8)
provide {
    io.Tasks      = rt                       @ Process
    io.Clock      = SystemClock()            @ Process
    io.Sleep      = FiberSleep(rt)           @ Process
    io.NetClient  = UringNet(rt)             @ Process
    io.NetServer  = UringNet(rt)             @ Process
    io.FileSystem = UringFs(rt)              @ Process
    io.MemoryMap  = PosixMmap()              @ Process
    io.Stdio      = FdStdio()                @ Process
    io.Signals    = PosixSignals(rt)         @ Process
    io.Process    = PosixProcess()           @ Process
    io.Entropy    = KernelRng()              @ Process
    io.Sync       = FiberSync(rt)            @ Process
} in { serve(8080, router()) }

// Edge / Workers-style: no server-side network, no filesystem, no subprocesses
provide {
    io.Tasks      = MicrotaskLoop()          @ Process
    io.Clock      = WallClock()              @ Process
    io.Sleep      = TimerSleep()             @ Process
    io.NetClient  = FetchNet()               @ Process
    io.Stdio      = ConsoleStdio()           @ Process
    io.Entropy    = WebCryptoRng()           @ Process
    io.Sync       = SingleThread()           @ Process
} in { handle_request_loop() }

// Deterministic test runtime
provide {
    io.Tasks      = SyncTasks()              @ Process
    io.Clock      = FixedClock(t0)           @ Process
    io.Sleep      = SkipSleep()              @ Process
    io.FileSystem = InMemoryFs()             @ Process
    io.Stdio      = CapturedStdio()          @ Process
    io.Entropy    = SeededRng(seed)          @ Process
    io.Sync       = SingleThread()           @ Process
} in { run_tests() }
```

The same user code runs on all three. Whether `Database.query(...)` blocks an OS thread, suspends a fiber, runs as a microtask, or returns immediately is the runtime's decision, not the user's. There is **no function coloring**: no `async`/`await` keywords, no two parallel standard libraries.

A target that does not bind a particular `io.*` capability does not break: any impl that requires the missing capability simply fails to compile inside that `provide` block, with the error pointing at the missing binding. Capability omission is an explicit, statically-checked target restriction.

### 2.7 Cancellation, `defer`, and `Timeout`

Cancellation is built on `with_cancel` and `CancelToken` (§2.6.3). `Cancelled` is a stdlib row variant any blocking operation may raise; the doc lists it in every `io.*` method that can suspend.

**Semantics.**

1. `io.Tasks.with_cancel(action)` introduces a fresh `CancelToken` for the duration of `action`. The token is captured by reference (typically by a sibling task or signal handler).
1. `token.trip()` returns immediately. It sets the cancellation flag; any operation currently parked inside this `with_cancel` (transitively) and any subsequent suspending operation raises `Cancelled` at its next suspension point.
1. `Cancelled` propagates like any other variant in a `raises` row. Catching it requires `try ... catch Cancelled -> ...`. Re-cancelling after catching requires explicit `raise Cancelled` from a `raises {Cancelled}` context.
1. `defer` blocks run on **every** function exit path: normal return, `raise` (including `Cancelled`), and panic. They run in LIFO order. A `defer` block runs to completion before exit continues; `defer` blocks are not themselves cancellable (a `Cancelled` raised from within a `defer` is a panic).

**Timeouts as a derived form.** v4 has no special-cased `with_timeout` primitive. Timeouts compose from `with_cancel` and `io.Sleep`:

```
fn with_timeout<R>(d: Duration, action: fn() -> R) -> R
    requires {io.Tasks, io.Sleep}
    raises   {Timeout}
{
    io.Tasks.with_cancel(|tok| {
        let timer = io.Tasks.async(|| { io.Sleep.sleep(d); tok.trip() })
        defer timer.cancel()
        try action() catch Cancelled -> raise Timeout
    })
}
```

`Timeout` is a distinct variant from `Cancelled` because callers want to distinguish "I gave up waiting" from "someone else cancelled me." `with_timeout` lives in stdlib and is the form most user code uses.

**Nested cancellation.** Nested `with_cancel` blocks introduce nested tokens. Tripping an outer token affects all enclosed operations; tripping an inner token affects only operations under that inner block. The runtime resolves "which token does this suspension belong to" by walking the fiber's cancel-scope stack (innermost first); any tripped scope raises `Cancelled`.

```
fn handle_request(req: Request) -> Response
    requires {Database, io.Tasks, io.Sleep, Logger}
    raises   {}
{
    try with_timeout(5.seconds) {
        do_expensive_thing()
    } catch Timeout -> Response.gateway_timeout()
}
```

**Budget propagation.** `io.Sleep.remaining()` returns the duration left under the innermost enclosing `with_timeout`, or `None` if no deadline is in effect. Fanout code uses this to budget per-item time:

```
fn batch_fetch(ids: List<Id>) -> List<Item>
    requires {io.Tasks, io.Sleep, Database}
    raises   {Timeout}
{
    let total = io.Sleep.remaining() ?? 30.seconds
    let per = total / ids.len().max(1)
    ids.map(|id| with_timeout(per) { fetch(id) })
}
```

**Cancel protection.** A block can be marked uncancellable for the duration of a critical section:

```
io.Tasks.with_cancel(|outer| {
    // ... cancellable work ...
    uncancellable {
        // outer.trip() during this block does NOT raise Cancelled here;
        // it raises at the next suspension point after the block exits.
        critical_section()
    }
})
```

This is needed for code that must finish a multi-step protocol (database transaction commit, mutex unlock, file rename) before honoring cancellation. Use sparingly; long uncancellable blocks make graceful shutdown impossible.

**CPU-bound code does not check cancellation automatically;** insert `io.Tasks.yield_now()` in long-running loops to give the runtime a chance to deliver `Cancelled`. This is a known limitation, identical to Go before preemption.

### 2.8 Raising and catching

Errors flow through `raises` rows. There is no `Result<T, E>` type in v4 — error handling uses only `raise`, `raises`, and `try ... catch`.

`raise` constructs an error of one of the variants in the function's `raises` row. `raise X` is an expression of type `Never` (see 2.15).

```
fn user_or_fail(id: Uuid) -> User
    requires {Database}
    raises   {NotFound}
{
    user_by_id(id) ?? raise NotFound
}
```

Errors are caught with `try ... catch`:

```
try fetch_user(id) catch {
    NotFound       -> Response.not_found()
    DbError(e)     -> { Logger.error("db", e); Response.server_error() }
}
```

The catch must be exhaustive over the inner function's `raises` row, or the outer function's `raises` row must include any uncaught variants. The compiler enforces this.

Re-tagging at service boundaries is explicit:

```
pub fn create_post(...) -> Post
    requires {PostRepo, SearchIndex, ...}
    raises   {BadInput, DbFailure, SearchFailure}
{
    try PostRepo.insert(post) catch DbError(e) -> raise DbFailure(e)
    try SearchIndex.index_post(post) catch SearchError(e) -> raise SearchFailure(e)
    // ...
}
```

This is deliberate. The verbosity makes error-domain boundaries visible at the call site. No `?` operator or `from` conversion is provided; promotion patterns live in libraries or are written out.

### 2.9 `provide` blocks and `Wiring` values

`provide ... in { ... }` is the only place capability implementations enter scope. It is a lexically-scoped expression.

```
provide {
    io.Tasks      = rt                              @ Process
    io.Stdio      = rt                              @ Process
    Database      = Postgres(io.Process.env("DB_URL") ?? "") @ Process
    Logger        = JsonLogger()                    @ Process
    Clock         = SystemClock()                   @ Process
} in {
    serve(8080, router())
}
```

**Every binding must specify its scope** with `@ ScopeName`. No defaults. A binding without `@` is a compile error.

**Wiring values.** A `provide { ... }` expression with no `in` block is a `Wiring` value — a first-class composable representation of a set of bindings. It can be stored, returned, passed, and combined.

```
fn base_runtime() -> Wiring {
    let rt = FiberRuntime(workers: 8)
    provide {
        io.Tasks      = rt              @ Process
        io.Sleep      = FiberSleep(rt)  @ Process
        io.NetClient  = rt              @ Process
        io.NetServer  = rt              @ Process
        io.FileSystem = rt              @ Process
        io.Stdio      = rt              @ Process
        io.Signals    = rt              @ Process
        io.Process    = PosixProcess()  @ Process
        io.Entropy    = KernelRng()     @ Process
        io.Sync       = FiberSync(rt)   @ Process
        Logger        = JsonLogger()    @ Process
        Clock         = SystemClock()   @ Process
        Metrics       = StatsdMetrics() @ Process
    }
}

fn web_app_caps(cfg: AppConfig) -> Wiring {
    provide {
        WriteDb     = Postgres(cfg.db_url)            @ Process
        TokenSigner = Hs256Signer(cfg.jwt_secret)     @ Process
        Mailer      = SmtpMailer(cfg.smtp)            @ Process
    }
}

fn main() {
    provide base_runtime() in {
        let cfg = load_config()
        provide web_app_caps(cfg) in {
            serve(cfg.port, router())
        }
    }
}
```

Two operators compose `Wiring` values:

- `w1 ++ w2` — merge. Bindings in `w2` shadow `w1` on collision.
- `w with { Cap = expr @ Scope }` — override. Same as `w ++ provide { Cap = expr @ Scope }` but reads better when the intent is replacement.

```
let test_base = provide {
    io.Tasks      = SyncTasks()             @ Process
    io.Sleep      = SkipSleep()             @ Process
    io.Stdio      = NullStdio()             @ Process
    io.Sync       = SingleThread()          @ Process
    io.Entropy    = SeededRng(0)            @ Process
    Logger        = TestLogger()            @ Process
    Clock         = FixedClock(t0)          @ Process
    IdGen         = SeqIdGen.fresh()        @ Process
}

let test_repos = provide {
    PostRepo    = InMemoryPostRepo() @ Process
    SearchIndex = SpySearchIndex()   @ Process
}

test "default success path" {
    provide test_base ++ test_repos in { /* ... */ }
}

test "search fails over" {
    provide test_base ++ test_repos with { SearchIndex = FailingSearchIndex() @ Process } in {
        /* ... */
    }
}
```

**Semantics:**

- The `in { ... }` block executes with the listed capabilities in scope.
- Nested `provide` blocks shadow outer bindings for the inner scope only.
- Within a single `provide` block, bindings see previously-listed bindings in lexical order. Forward references are a compile error. (This rules out construction-order cycles before they can occur; cycles in `Lifecycle.start()` are caught separately — see 2.10.)
- On exit (normal, `raise`, or panic), `Lifecycle.shutdown(exit)` runs on every started impl in reverse order of startup.
- `provide` is an expression; it returns whatever its `in { ... }` block returns.
- Implementations with non-empty `requires` rows must have those caps satisfied at construction time.

### 2.10 `Lifecycle`, `Drop`, and `ExitReason`

The language has two cleanup mechanisms, applied at different layers.

**`Lifecycle`** is for impls bound in `provide` blocks. It is a trait:

```
enum ExitReason {
    Normal
    Raised(error: Error)
    Panicked
}

trait Lifecycle {
    fn start() raises {StartupError}
    fn shutdown(exit: ExitReason)
}
```

`start()` runs on every entry into a `provide` block where the impl is bound, in topological order over the `requires` rows on `start` methods. `shutdown(exit)` runs on every exit from that block, in reverse order. The `ExitReason` argument indicates how the block was left.

This applies per scope-instance entry: Process-scoped impls get `start()` once per program; Request-scoped impls get `start()` per request entry; Transaction-scoped impls get `start()` per transaction entry. Impls with no per-entry work simply leave `Lifecycle` unimplemented and do their setup in the constructor expression.

**Startup ordering.** Topological sort over the `requires` rows on `start` methods. If `Mailer.start()` requires `{Logger}`, `Logger.start()` runs first. Cycles are compile errors.

**Tie-breaking.** When two impls have no startup-order constraint between them (neither's `requires` mentions the other), they are started in **lexical declaration order within the `provide` block**. Shutdown runs in reverse, so siblings shut down in reverse declaration order. This is observable: drain-before-close orderings depend on it.

```
// FiberInFlight is declared after ReadDb, so FiberInFlight shuts down FIRST.
// Handlers in flight can use the DB while they drain.
provide {
    ReadDb        = Postgres(...)            @ Process
    FiberInFlight = FiberInFlight()          @ Process    // shuts down before Postgres
} in { ... }
```

If your shutdown order depends on a particular relationship, encode it explicitly: make the dependent impl's `Lifecycle.requires` include the impl it depends on, so the topology pins the order rather than relying on declaration sequence.

**Startup failure.** If any `start()` raises `StartupError`, the `provide` block runs `shutdown(Raised(error))` on every previously-started impl in reverse order, then re-raises the original `StartupError` to the caller. The impl whose `start()` raised is **not** sent a `shutdown` — it never finished starting, so it has nothing to tear down. Shutdown methods that themselves raise during cleanup log to `io.Stdio.stderr` and are otherwise ignored; the original `StartupError` is what propagates.

**Worked example: Postgres.**

```
impl Lifecycle for Postgres {
    requires {io.NetClient, io.Sleep, Logger}

    fn start() raises {StartupError} {
        Logger.info("connecting to ${self.url}")
        self.pool = ConnectionPool.connect(self.url)
        io.Tasks.async(|| self.health_check_loop())
    }
    fn shutdown(exit: ExitReason) {
        match exit {
            Normal      -> { self.pool.drain(timeout: 30.seconds) }
            Raised(e)   -> { Logger.warn("draining after error", {"err": e.to_str()})
                             self.pool.drain(timeout: 10.seconds) }
            Panicked    -> { self.pool.close_all() }
        }
    }
}
```

**Worked example: transactions.**

```
impl Lifecycle for PostgresTransaction {
    requires {Logger}

    fn start() raises {StartupError} {
        self.conn.execute("BEGIN")
    }

    fn shutdown(exit: ExitReason) {
        match exit {
            Normal      -> { self.conn.execute("COMMIT") }
            Raised(_)   -> { self.conn.execute("ROLLBACK") }
            Panicked    -> { self.conn.execute("ROLLBACK")
                             Logger.error("tx panicked") }
        }
    }
}
```

The commit-on-success, rollback-on-error pattern is just `Lifecycle.shutdown` dispatching on `ExitReason`. No special transaction syntax.

**`Drop`** is a lang-item trait for ordinary values:

```
trait Drop {
    fn drop()
}
```

`drop()` runs when a value goes out of lexical scope. Used for transient resources held on the stack: file handles, locks, transaction guards, stream values. Unlike `Lifecycle`, `Drop` is not tied to `provide` blocks; it tracks value lifetimes through the program.

**The boundary.** Is the thing bound in a `provide` block, or is it a value moving through the program? Bound → `Lifecycle`. Value → `Drop`. An impl used both ways implements both. A `Lifecycle`-bound impl's `shutdown()` does *not* fire when an internal field goes out of scope — only the field's `Drop` does. The two mechanisms operate independently.

### 2.11 Scopes

A scope is a declared lifetime region within which scoped capabilities have a fresh instance per entry.

```
scope Request
scope Transaction
scope HtmlRender
```

`Process` is the implicit root scope. Every program runs inside a Process scope.

A capability annotated `@ ScopeName` may be bound only in a `provide` block targeting that scope. The `provide` block specifies its target scope with `@`:

```
provide @ Request {
    RequestCtx = fresh_ctx(req) @ Request
    Tenant     = lookup_tenant(req) @ Request
} in {
    handler()
}
```

Re-entry is explicit: the framework re-enters `provide @ Request` per request, yielding a fresh `RequestCtx` and `Tenant` each time. Web frameworks expose this as a hook; user code can also re-enter manually.

Transaction scope:

```
fn create_post(...)
    requires {WriteDb, IdGen, Clock}
    raises   {BadInput, DbFailure}
{
    provide @ Transaction {
        DbTx = WriteDb.begin() @ Transaction
    } in {
        // DbTx.execute(...), DbTx.query(...) inside this block
        // Normal exit → commit via Lifecycle.shutdown(Normal)
        // raise        → rollback via Lifecycle.shutdown(Raised(_))
    }
}
```

The compiler rejects `DbTx.execute(...)` outside a `Transaction` scope — a category of bug previously catchable only by convention.

### 2.12 Streams and iteration

`Stream<T>` is a stdlib struct that implements `Iterator<T>` (lang item) and `Drop`. It is constructed with the `stream { yield ... }` expression.

```
struct Stream<T> { /* internal state */ }

impl<T> Iterator<T> for Stream<T> {
    fn next() -> T? raises {StreamError} { /* ... */ }
    fn close() { /* ... */ }
}

impl<T> Drop for Stream<T> {
    fn drop() { self.close() }
}

pub fn posts_stream(filter: PostFilter) -> Stream<Post>
    requires {PostRepo}
    raises   {DbFailure}
{
    stream {
        let mut page = Page.first()
        loop {
            let batch = try PostRepo.list(page, filter) catch DbError(e) -> raise DbFailure(e)
            for post in batch.items { yield post }
            if !batch.has_more { break }
            page = batch.next
        }
    }
}

// HTTP streaming response composes naturally with cancellation
pub fn export_posts(filter: PostFilter) -> Response
    requires {PostRepo, io.Tasks, io.Sleep, Logger}
    raises   {}
{
    Response.streaming { writer ->
        try for post in posts_stream(filter) {
            writer.write_line(json_stringify(post))
        } catch DbFailure(e) -> {
            Logger.error("export failed", e)
            writer.abort()
        }
    }
}
```

Each `yield` is a suspension point: cancellation via `with_timeout` or `with_cancel` propagates into stream consumption. The `for x in stream_expr { ... }` syntax desugars to a loop calling `.next()`, with the iterator dropped (via `Drop`) on loop exit.

`Iterator<T>` is a trait, not a capability. Custom iterators (paginated cursors, sensor feeds, etc.) implement it directly with `impl Iterator<T> for MyType { ... }`.

### 2.13 Default methods on capabilities and traits

Capability and trait methods may have default bodies. An impl that does not override a defaulted method inherits the default. The default body's `requires` row contributes to the impl's effective row when the defaulted method is reachable through the trait or capability surface.

**Rule (default-method row contribution).** The impl's effective `requires` row is the union of:

1. The `requires` declared on the impl itself.
1. The rows of all method bodies the impl provides.
1. The rows of all defaulted method bodies the impl does *not* override.

Defaults that recursively call other defaults contribute only their own body's row; the called default's row is added independently by the same rule. The compiler verifies that the impl-level declared `requires` matches the computed effective row exactly. Over-declaration is an error, same as for functions.

**Worked example.**

```
capability Logger {
    fn info(msg: Str, fields: Map<Str, Json> = {})
    fn warn(msg: Str, fields: Map<Str, Json> = {})

    // Default uses io.Stdio directly; impls inheriting this default
    // pick up the {io.Stdio} requirement automatically.
    fn flush() {
        io.Stdio.stdout("\n")
    }

    // Default calls self.info; row contribution is empty
    fn debug(msg: Str) {
        self.info("[DEBUG] ${msg}")
    }
}

// Inherits both defaults. Effective impl requires: {io.Stdio}
//   - flush is reachable (it's part of the capability surface);
//     its default body uses {io.Stdio}.
//   - debug is reachable; its default body uses self.info (no extra row).
//   - info and warn are required, declared below.
impl Logger for JsonLogger {
    requires {io.Stdio}
    fn info(msg: Str, fields: Map<Str, Json>) { io.Stdio.stdout(/* ... */) }
    fn warn(msg: Str, fields: Map<Str, Json>) { io.Stdio.stdout(/* ... */) }
}

// Overrides flush; loses flush's {io.Stdio} contribution. Effective row: {}
impl Logger for InMemoryLogger {
    requires {}
    fn info(msg: Str, fields: Map<Str, Json>) { self.entries.push(/* ... */) }
    fn warn(msg: Str, fields: Map<Str, Json>) { self.entries.push(/* ... */) }
    fn flush() {}                                  // override; default's row drops
}
```

The "matches exactly" property is what keeps impl `requires` rows trustworthy: readers can trust the declared row is what the impl actually needs, including via inherited defaults.

Adding a defaulted method is a non-breaking change when the default has empty `requires`. Adding a defaulted method with a non-empty `requires` row is a breaking change to every impl that inherits the default — those impls' effective rows grow.

### 2.14 Generics

Generic parameters appear on functions, capabilities, traits, structs, enums, and impls. Syntax: `<G1, G2, ...>`.

**Trait constraint bounds.** A generic parameter may be constrained by one or more traits, separated by `+`. Capabilities cannot appear as constraints — they belong in `requires` rows, not in type bounds.

```
fn sort<T: Ord>(xs: List<T>) -> List<T> { /* ... */ }

fn dedup<T: Eq + Hash>(xs: List<T>) -> List<T> { /* ... */ }

// Capabilities are not constraints — this is an error:
// fn log_all<T, L: Logger>(xs: List<T>) { ... }    // ERROR
// Logger goes in requires:
fn log_all<T: Display>(xs: List<T>) requires {Logger} {
    for x in xs { Logger.info(x.to_str()) }
}
```

**Where clauses** carry complex constraints out of the parameter list:

```
fn merge<K, V, M>(a: M, b: M) -> M
    where M: Map<K, V>, K: Eq + Hash
{ /* ... */ }
```

**Generic structs and enums.**

```
struct Cached<T> { value: T, cached_at: Instant }

enum Option<T> {
    Some(T)
    None
}
```

**Generic capabilities and traits.**

```
capability Cache<K, V> @ Process | Request
    where K: Eq + Hash
{
    fn get(key: K) -> V?
    fn put(key: K, val: V)
}

trait Iterator<T> {
    fn next() -> T?
}
```

**Row parameters.** Generic parameters used in row positions (inside `requires {...}` or `raises {...}`) are inferred to be rows rather than types. The two domains do not share names: a parameter `R` used only in row position is a row variable.

```
type Handler<R> = fn(Request) -> Response requires {R} raises {}

struct Router<R> { /* ... */ }
impl<R> Router<R> {
    fn get<R2>(self, pat: Str, h: Handler<R2>) -> Router<R + R2> { /* ... */ }
}
```

Row parameters cannot be constrained by trait bounds (they are not types). They can be combined using `+` per §2.3.

**Generic impls.** Parameters on `impl<...>` are bound for the whole block; they appear in both the implemented interface and the implementing type.

```
impl<T> Iterator<T> for Stream<T> { /* ... */ }

impl<K, V> Cache<K, V> for LruCache<K, V>
    where K: Eq + Hash
{ /* ... */ }
```

**Type aliases** with generics:

```
type Handler<R> = fn(Request) -> Response requires {R} raises {}
```

Variance, higher-kinded types, associated types, and generalized associated types (GATs) are deferred — see section 8. All generic parameters in v4 are invariant; this is restrictive but well-defined.

### 2.15 `Never`

`Never` is the bottom type — a subtype of every type, with no inhabitants. Expressions that do not produce a value have type `Never`:

- `return X` — exits the enclosing function with value `X`.
- `raise X` — raises an error of variant `X` from the enclosing function.
- `panic(msg)` — aborts the program.
- Diverging loops (`loop { }` with no `break` and no `return`/`raise` inside).

`Never` slots into any expression context. Its purpose is making early-exit constructs composable with operators that expect values:

```
let user = RequestCtx.current_user() ?? return Response.unauthorized()
let header = req.header("X-Tenant") ?? raise BadInput("missing tenant")
```

Here `return Response.unauthorized()` has type `Never`, which unifies with `User` (the unwrapped type of the left side), making the `??` expression well-typed.

Functions that never return normally have return type `Never`:

```
fn panic(msg: Str) -> Never { /* abort */ }
fn forever() -> Never { loop { do_work() } }
```

### 2.16 `Option` and absence handling

`Option<T>` is a stdlib enum:

```
enum Option<T> {
    Some(T)
    None
}
```

The type sugar `T?` is shorthand for `Option<T>`. `User?` parses to `Option<User>`. The two forms are interchangeable; the `?` suffix is preferred in field types and signatures.

**`?.` (optional chaining)** desugars to a match on the receiver:

- `x?.method(args)` desugars to `match x { Some(v) -> Some(v.method(args)); None -> None }`.
- `x?.field` desugars analogously.
- The result type is always `Option<U>` where `U` is what the operation produces on a non-optional receiver.

Chains compose: `x?.foo()?.bar()` is two nested matches. If `bar` itself returns `Option<U>`, the chain flattens to `Option<U>` rather than `Option<Option<U>>` — this is the one place the desugaring inserts an explicit flatten step.

**`??` (null coalescing)** is a binary operator:

- `x ?? fallback` desugars to `match x { Some(v) -> v; None -> fallback }`.
- `fallback` is evaluated lazily; only if `x` is `None`.
- The right-hand side has any type that unifies with `T` (the unwrapped type of the left), including `Never`. This is what makes `?? return X` and `?? raise X` work.

```
let user = RequestCtx.current_user() ?? return Response.unauthorized()
let h = req.header("Authorization")?.strip_prefix("Bearer ") ?? raise BadInput("missing")
```

The `?` in `?.` is *not* the same as Rust's `?` operator for error propagation. This language does not have an error-propagation operator (see 2.8). The only `?` syntax in v4 is `?.` for optional chaining and the type suffix `T?`.

### 2.17 Stdlib lang items

The compiler knows the following traits by name and uses them to desugar built-in syntax. User code can `impl` them like any other trait; renaming or shadowing them is a hard error.

|Trait        |Method                           |Built-in syntax                       |
|-------------|---------------------------------|--------------------------------------|
|`Drop`       |`fn drop()`                      |scope exit; goes-out-of-scope cleanup |
|`Iterator<T>`|`fn next() -> T?`                |`for x in iter { ... }`               |
|`Eq`         |`fn eq(other: Self) -> Bool`     |`==`, `!=`                            |
|`Ord`        |`fn cmp(other: Self) -> Ordering`|`<`, `<=`, `>`, `>=`, sort routines   |
|`Hash`       |`fn hash<H: Hasher>(h: H)`       |`Map<K, V>`, `Set<T>` keying          |
|`Display`    |`fn fmt(w: Writer)`              |`"${x}"` string interpolation, `print`|
|`Clone`      |`fn clone() -> Self`             |explicit duplication                  |

Sync primitives (`Mutex<T>`, `Channel<T>`, `Condvar`, `Semaphore`) and concurrency values (`Future<R, E>`, `Group<R, E>`) are stdlib value types, **not** lang items. They are produced by `io.Sync` and `io.Tasks` respectively, and their methods carry capability requirements rather than receiving compiler-level special treatment.

### 2.18 Compile-time guarantees

A program that builds is guaranteed to have:

1. Every required capability provided by some lexically-enclosing `provide` block.
1. Every scope annotation consistent: scoped capabilities used only within their declared scope.
1. Every `raise` either caught downstream or declared in the surrounding `raises` row.
1. Every impl with a non-empty `requires` row constructed inside a `provide` block satisfying those caps.
1. No startup-time `Lifecycle.start()` cycles.
1. No construction-order cycles within a single `provide` block (forward references rejected).
1. Every `pub` function's declared rows matching its body's inferred rows exactly.
1. `defer` blocks present on every exit path including `Cancelled`, `Timeout`, `raise`, and panic.
1. Every `provide` binding carrying an explicit `@ ScopeName`.
1. Generic-parameter trait bounds satisfied at every use site.

-----

## 3. Syntax reference

### 3.1 Function declarations

```
[pub] fn name<G1, G2: Bound>(p1: T1, p2: T2) -> ReturnType
    requires {Cap1, Cap2 + R, Cap3<T>}
    raises   {Err1, Err2(payload: T)}
    where    G1: SomeTrait
{ body }
```

### 3.2 Function types

```
fn(T1, T2) -> ReturnType
    requires {...}
    raises   {...}
```

The leading `fn` is required. Nullary form: `fn() -> ReturnType`.

### 3.3 Capability declarations

```
capability Name [@ S1 | S2] [extends Other1 + Other2] [where bounds] {
    fn required_method(params) -> Return [raises {...}]
    fn defaulted_method(params) -> Return [raises {...}] { body }
}
```

### 3.4 Trait declarations

```
trait Name<T1, T2: Bound> [extends Other1 + Other2] [where bounds] {
    fn required_method(params) -> Return [raises {...}]
    fn defaulted_method(params) -> Return [raises {...}] { body }
}
```

`self` is implicit in method bodies; it is not declared as a parameter.

### 3.5 Scope declarations

```
scope ScopeName
```

### 3.6 Implementations

```
impl[<G1, G2: Bound>] Cap1 [+ Cap2 + Cap3] for Type[<G1, G2>] [where bounds] {
    [requires {...}]
    fn method1(params) -> Return { body }
    fn method2(params) -> Return { body }
}
```

### 3.7 Provide blocks and Wiring values

```
// Inline form (every binding specifies @ Scope)
provide [@ Scope] {
    CapName1 = expr1 @ Scope1
    CapName2<T> = expr2 @ Scope2
} in {
    body
}

// Wiring value (no `in`)
let w: Wiring = provide { ... }

// Instantiate a Wiring value
provide w in { body }

// Compose
let w12 = w1 ++ w2
let w_modified = w with { Cap = expr @ Scope }
```

### 3.8 Stream construction

```
stream { yield expr; ... }                          // expression of type Stream<T>
for x in iter_expr { ... }                          // iterates any Iterator<T>; closes via Drop
```

### 3.9 Error operations

```
raise ErrorVariant(args)                            // expression of type Never

try expr catch {
    Variant1       -> handler1
    Variant2(x)    -> handler2
}
```

### 3.10 Optional handling

```
T?                                                  // sugar for Option<T>
x?.method(args)                                     // optional chaining
x ?? fallback                                       // null coalescing
```

### 3.11 Defer and cancellation

```
defer { cleanup_code }                              // runs on every exit path

io.Tasks.with_cancel(|tok| { ... })                 // introduces a CancelToken
with_timeout(d) { ... }                             // stdlib; raises Timeout on expiry
uncancellable { ... }                               // suppresses Cancelled within block
select { fut_a.await() -> ...; fut_b.await() -> ... }   // multi-future blocking
```

### 3.12 Bindings and mutation

```
let x = expr                                        // immutable binding
let mut x = expr                                    // mutable binding (reassignable)
```

`mut` is a binding modifier only. There are no `Mut*` types and no `mut` on method parameters. Whether a method mutates the receiver is not visible in its signature.

### 3.13 Generic parameters

```
<G1, G2: Bound, G3: Bound1 + Bound2>                // declaration
fn name<T: Eq + Hash>(...) -> ...                   // usage on functions
impl<T> Trait<T> for Type<T> { ... }                // usage on impls
struct S<T> { ... }                                 // usage on structs
trait Tr<T> { ... }                                 // usage on traits
```

`where` clauses are equivalent to inline bounds but allow more complex expressions. Row parameters are recognized by appearing in row position (`requires {R}`, `raises {E}`) — see §2.14.

-----

## 4. Worked examples

### 4.1 Repository → Service → Controller

```
// Capabilities
capability Logger { /* see 2.13 */ }
capability Clock @ Process { fn now() -> Instant }
capability IdGen @ Process { fn next() -> Uuid }
capability PasswordHash @ Process {
    fn hash(pw: Str) -> Str
    fn verify(pw: Str, hash: Str) -> Bool
}

capability ReadDb {
    fn query(sql: Sql) -> Rows raises {DbError}
}
capability WriteDb extends ReadDb {
    fn execute(sql: Sql) -> Unit raises {DbError}
    fn transaction<R, E>(block: fn() -> R requires {WriteDb} raises {E}) -> R
        raises {E, DbError}
}

capability RequestCtx @ Request {
    fn request_id() -> Uuid
    fn current_user() -> User?
    fn with_user(user: User) -> RequestCtx
}

// Domain
struct User { id: Uuid, email: Email, name: Str }
struct Task { id: Uuid, owner: Uuid, title: Str, done: Bool, created_at: Instant }
struct CreateTaskInput { title: Str }

enum AppError {
    NotFound
    Forbidden
    BadInput(reason: Str)
    EmailTaken
    InvalidCredentials
    DbFailure(DbError)
}

// Private repo helpers
fn user_by_id(id: Uuid) -> User? {
    ReadDb.query(sql"SELECT * FROM users WHERE id = ${id}")
        .first().map(User.from_row)
}

// Public service
pub fn create_task(owner: Uuid, input: CreateTaskInput) -> Task
    requires {WriteDb, Logger, Clock, IdGen}
    raises   {BadInput, DbFailure}
{
    if input.title.trim().is_empty() { raise BadInput("title required") }
    let task = Task {
        id: IdGen.next(), owner, title: input.title,
        done: false, created_at: Clock.now(),
    }
    try WriteDb.execute(sql"INSERT INTO tasks ...") catch DbError(e) -> raise DbFailure(e)
    Logger.info("created task ${task.id}")
    task
}

// Middleware — row-polymorphic
fn with_request_logging<R, E>(handler: fn() -> Response requires {R} raises {E}) -> Response
    requires {R, Logger, Clock, RequestCtx}
    raises   {E}
{
    let start = Clock.now()
    let id = RequestCtx.request_id()
    Logger.info("[${id}] →")
    let res = handler()
    Logger.info("[${id}] ← ${res.status} (${Clock.now() - start})")
    res
}

fn with_auth<E>(
    req: Request,
    handler: fn() -> Response requires {RequestCtx} raises {E}
) -> Response
    requires {ReadDb, TokenSigner, RequestCtx}
    raises   {E}
{
    let token = req.header("Authorization")?.strip_prefix("Bearer ")
        ?? return Response.unauthorized()
    let claims = TokenSigner.verify(token) ?? return Response.unauthorized()
    let user = user_by_id(claims.sub) ?? return Response.unauthorized()

    provide @ Request { RequestCtx = RequestCtx.with_user(user) @ Request } in {
        handler()
    }
}

// Wiring at main
fn main() {
    let rt = FiberRuntime(workers: 8)
    provide {
        io.Tasks      = rt                                          @ Process
        io.Sleep      = FiberSleep(rt)                              @ Process
        io.NetClient  = rt                                          @ Process
        io.NetServer  = rt                                          @ Process
        io.FileSystem = rt                                          @ Process
        io.Stdio      = rt                                          @ Process
        io.Signals    = rt                                          @ Process
        io.Process    = PosixProcess()                              @ Process
        io.Entropy    = KernelRng()                                 @ Process
        io.Sync       = FiberSync(rt)                               @ Process
        WriteDb       = Postgres(io.Process.env("DB_URL") ?? "")    @ Process
        Logger        = JsonLogger()                                @ Process
        Clock         = SystemClock()                               @ Process
        IdGen         = UuidV7Gen()                                 @ Process
        PasswordHash  = Argon2(cost: 12)                            @ Process
        TokenSigner   = Hs256Signer(io.Process.env("JWT_SECRET") ?? panic("JWT_SECRET")) @ Process
    } in {
        serve(8080, router())
    }
}
```

Note `io.Process.env("DB_URL")` instead of `env.DB_URL` — config access is an explicit capability call in v4.

### 4.2 Multi-tenant via scoped override

`TenantRegistry.database_for` returns a concrete impl type. This limits multi-tenancy to configuration variation within one backend kind; mixing backend *kinds* per tenant requires the first-class-capability-values upgrade noted in section 8.

```
capability TenantRegistry @ Process {
    fn database_for(tenant: TenantId) -> Postgres
    fn lookup(tenant: TenantId) -> TenantInfo?
}

capability Tenant @ Request {
    fn id() -> TenantId
    fn name() -> Str
}

fn with_tenant<R, E>(
    req: Request,
    handler: fn() -> Response requires {R + WriteDb + Tenant} raises {E}
) -> Response
    requires {R, TenantRegistry, Logger}
    raises   {E}
{
    let tid = req.header("X-Tenant").and_then(TenantId.parse)
        ?? return Response.bad_request("missing tenant")
    let db = TenantRegistry.database_for(tid)
    let info = TenantRegistry.lookup(tid) ?? return Response.not_found()

    provide @ Request {
        WriteDb = db   @ Request
        Tenant  = info @ Request
    } in {
        handler()
    }
}
```

### 4.3 Cancellation in action

```
pub fn search_external(query: Str) -> List<Hit>
    requires {HttpClient, io.Tasks, io.Sleep, Logger}
    raises   {AppError}
{
    try with_timeout(2.seconds) {
        let response = HttpClient.get("https://search.example.com?q=${query}")
        json_parse<List<Hit>>(response.body)
    } catch {
        Timeout    -> { Logger.warn("search timeout"); [] }
        HttpError  -> raise AppError.UpstreamError
    }
}
```

The `Timeout` propagates from inside `HttpClient.get` because the underlying `io.NetClient.read`/`write` calls run under the `with_cancel` scope that `with_timeout` set up, and the timer task's `tok.trip()` causes those reads to raise `Cancelled`, which `with_timeout` retags as `Timeout`. Note the signature: success path returns `List<Hit>` directly, errors flow through `raises`. No `Result`.

### 4.4 Tests with composable Wiring

```
fn test_runtime() -> Wiring {
    provide {
        io.Tasks      = SyncTasks()                              @ Process
        io.Sleep      = SkipSleep()                              @ Process
        io.Stdio      = NullStdio()                              @ Process
        io.Sync       = SingleThread()                           @ Process
        io.Entropy    = SeededRng(0)                             @ Process
        Logger        = TestLogger()                             @ Process
        Clock         = FixedClock(Instant.parse("2026-05-21T12:00Z")) @ Process
        IdGen         = SeqIdGen([Uuid.parse("t1")])             @ Process
    }
}

test "create_task persists task" {
    let db = InMemoryDb()
    provide test_runtime() ++ provide { WriteDb = db @ Process } in {
        let task = create_task(Uuid.parse("u1"), CreateTaskInput { title: "buy milk" })
        assert task.title == "buy milk"
        assert db.tasks.len() == 1
    }
}

test "create_task rejects empty title" {
    provide test_runtime() ++ provide { WriteDb = InMemoryDb() @ Process } in {
        try create_task(Uuid.parse("u1"), CreateTaskInput { title: "  " }) catch {
            BadInput(_) -> {}                            // expected
            other       -> assert false, "unexpected: ${other}"
        }
    }
}
```

### 4.5 Streaming a large export

```
pub fn export_all_tasks(owner: Uuid) -> Response
    requires {ReadDb, io.Tasks, io.Sleep, Logger}
    raises   {}
{
    Response.streaming { writer ->
        try for task in tasks_stream(owner) {
            writer.write_line(json_stringify(task))
        } catch DbFailure(e) -> {
            Logger.error("export failed", e)
            writer.abort()
        }
    }
}

fn tasks_stream(owner: Uuid) -> Stream<Task>
    requires {ReadDb}
    raises   {DbFailure}
{
    stream {
        let mut cursor = TaskCursor.start_for(owner)
        loop {
            let batch = try ReadDb.query(cursor.next_page_sql())
                catch DbError(e) -> raise DbFailure(e)
            for row in batch { yield Task.from_row(row) }
            if batch.len() < cursor.page_size { break }
            cursor = cursor.advance()
        }
    }
}
```

The stream closes (and the cursor releases) whether the client reads to completion, the connection drops, or an enclosing `with_timeout` fires — via `Drop` on the `Stream<Task>` value.

### 4.6 Background jobs

```
capability JobQueue @ Process {
    fn enqueue<R, E>(job: fn() -> Unit requires {R} raises {E})
        requires {R}
        raises {QueueError}
}

fn send_welcome_email(user: User) requires {Mailer, Logger} {
    Mailer.send(user.email, "Welcome", render_welcome(user))
    Logger.info("welcome email sent", {"user_id": user.id})
}

pub fn register_with_welcome(input: RegisterInput) -> User
    requires {WriteDb, Logger, JobQueue, Mailer}
    raises   {EmailTaken, QueueError}
{
    let user = register_user(input.email, input.name, input.password)
    JobQueue.enqueue { send_welcome_email(user) }
    user
}
```

The closure passed to `enqueue` requires `{Mailer, Logger}` (inferred from the body), so the enqueue call requires them in scope at the call site. The worker process that later runs the job must be wired with at least the same capabilities — the compiler verifies the producer side; the consumer-side match is an integration concern.

### 4.7 Transaction scope and `Lifecycle`

```
capability DbTx @ Transaction {
    fn execute(sql: Sql) raises {DbError}
    fn query(sql: Sql) -> Rows raises {DbError}
}

struct PostgresTransaction { conn: Connection }

impl DbTx for PostgresTransaction {
    fn execute(sql: Sql) raises {DbError} { self.conn.execute(sql) }
    fn query(sql: Sql) -> Rows raises {DbError} { self.conn.query(sql) }
}

impl Lifecycle for PostgresTransaction {
    requires {Logger}
    fn start() raises {StartupError} {
        self.conn.execute("BEGIN")
    }
    fn shutdown(exit: ExitReason) {
        match exit {
            Normal    -> self.conn.execute("COMMIT")
            Raised(_) -> self.conn.execute("ROLLBACK")
            Panicked  -> { self.conn.execute("ROLLBACK"); Logger.error("tx panicked") }
        }
    }
}

fn create_post(input: CreatePostInput) -> Post
    requires {WriteDb, IdGen, Clock, Logger}
    raises   {BadInput, DbFailure}
{
    provide @ Transaction {
        DbTx = PostgresTransaction { conn: WriteDb.acquire() } @ Transaction
    } in {
        // ... uses DbTx.execute / DbTx.query ...
        // Normal exit → COMMIT; raise → ROLLBACK; panic → ROLLBACK + log
    }
}
```

### 4.8 HTTP server with graceful shutdown

```
// Handlers — each declares exactly what it touches.
fn hello(req: Request) -> Response requires {Logger} {
    Logger.info("hit", {"path": req.path})
    Response.ok("Hello, world!\n".bytes())
}

fn now(req: Request) -> Response requires {Clock} {
    Response.ok("Current time: ${Clock.now()}\n".bytes())
}

fn tasks(req: Request) -> Response requires {ReadDb, Logger} {
    let id = req.path_param("id").and_then(Uuid.parse)
        ?? return Response.bad_request("bad id")
    try {
        let row = ReadDb.query(sql"select title from tasks where id = ${id}")
            .first() ?? return Response.not_found()
        Response.ok("${row.title}\n".bytes())
    } catch DbError(e) -> {
        Logger.error("db", e)
        Response.server_error()
    }
}

fn router() -> Router<{Logger, Clock, ReadDb}> {
    Router.new()
        .get("/",          hello)
        .get("/time",      now)
        .get("/tasks/:id", tasks)
}

pub fn serve<R>(port: U16, router: Router<R>)
    requires {R, io.Tasks, io.NetServer, io.Signals, io.Sync, Logger}
    raises   {IoError}
{
    let listener = io.NetServer.bind(SocketAddr.any(port))
    defer io.NetServer.close(listener)
    Logger.info("listening", {"port": port})

    let inflight: Group<Unit, Never> = Group.new()

    // Signal-watcher closes the listener to break the accept loop.
    io.Tasks.async(|| {
        let sig = io.Signals.wait_for([Signal.TERM, Signal.INT])
        Logger.info("shutdown signal", {"signal": sig})
        io.NetServer.close(listener)
    })

    loop {
        let sock = try io.NetServer.accept(listener)
                   catch IoError(_) -> break        // listener closed
        inflight.concurrent(|| handle_conn(sock, router))
    }

    // Drain in-flight handlers under a generous timeout; surface failures.
    try with_timeout(30.seconds) { inflight.await() }
    catch {
        Timeout   -> Logger.warn("drain incomplete; remaining handlers cancelled after grace")
        Cancelled -> {}    // propagated from a member; already logged elsewhere
    }
}

fn handle_conn<R>(sock: Socket, router: Router<R>)
    requires {R, io.NetClient, io.Tasks, io.Sleep, Logger}
{
    defer io.NetClient.close(sock)

    try with_timeout(30.seconds) {
        let req = read_request(sock)
        provide @ Request {
            RequestCtx = RequestCtx.fresh(req) @ Request
        } in {
            let resp = router.dispatch(req)
                .map(|h| h(req))
                .unwrap_or_else(|| Response.not_found())
            write_response(sock, resp)
        }
    } catch {
        Timeout    -> Logger.warn("request timeout")
        IoError(e) -> Logger.warn("connection error", {"err": e})
    }
}
```

`Group<Unit, Never>` replaces the v3-era pattern of hand-rolling an in-flight tracker. Shutdown semantics fall out: when the listener closes, `serve` exits the accept loop, `await`s the group with a grace budget, then returns. The enclosing `provide` block at `main` runs `shutdown(Normal)` over all `Lifecycle` impls in reverse declaration order.

-----

## 5. Type system summary

Additions over a standard ML/Rust-style base:

1. **Effect rows** — sets of capabilities and errors, attached to function arrows.
1. **Row variables** — generic parameters that abstract over rows, enabling middleware polymorphism.
1. **Row arithmetic** — `R + Cap` extends row `R` with `Cap`; `R + S` unions two row variables. The compiler unifies on row equivalence (set equality up to order). `+` is associative and commutative.
1. **Capability subtyping** — derived from `extends`; a row requirement of `{ReadDb}` is satisfied by an impl of `WriteDb`.
1. **Lexical capability resolution** — at any use site of `Cap.method()`, the compiler walks outward through enclosing `provide` blocks to find a binding. If none exists, compile error. If multiple bind the same cap, the innermost wins.
1. **Impl-private requires** — impl-level `requires` rows are satisfied at impl construction and do not propagate to callers.
1. **Scope annotations and checking** — `@ ScopeName` constrains both capability declarations and use sites. Use of a `@ Request`-only capability outside a `Request` scope is a compile error.
1. **`Wiring` as a first-class value type** — `provide { ... }` (no `in`) is a value of type `Wiring`. `++` and `with` are operators on `Wiring`.
1. **Default methods on capabilities and traits** — non-breaking evolution for empty-row defaults. Default body's `requires` row contributes to impl rows when reachable.
1. **`Never` as bottom type** — subtype of every type; expressions like `return`, `raise`, `panic` have this type; enables `?? return X` and similar.
1. **Traits parallel to capabilities** — trait conformance is receiver-resolved; capability conformance is `provide`-resolved. Both use `impl X for Type` syntax.
1. **Generics with trait bounds only** — generic parameters accept trait constraints; capabilities are not constraints (they live in `requires` rows). Generic parameters in row position are row variables.

Capability resolution is **static** — there is no runtime container, no reflection, no DI graph built at startup. The compiler emits direct calls to the resolved implementation, with capabilities passed as hidden arguments through the call chain (or specialized away by monomorphization, depending on the implementation strategy).

-----

## 6. Compile-time guarantees, restated

The following are statically impossible:

- A function calling a capability method without that capability in its `requires` row (or available in lexical scope).
- An entry point whose required capabilities aren't all provided.
- A scoped capability used outside its declared scope.
- A `raise` for a variant not declared in the function's `raises` row.
- An unhandled error variant escaping a `try ... catch`.
- A startup cycle where two capabilities' `start()` methods require each other.
- A construction cycle within a `provide` block (forward references rejected).
- A `pub` function whose body uses capabilities not declared in its `requires` row, or whose declared row over-states what the body uses.
- Constructing an impl whose `requires {...}` row is not satisfied at the `provide` site.
- A `defer` block omitted on a `Cancelled`, `Timeout`, or panic exit path (defers run on every exit).
- A `provide` binding without an explicit `@ ScopeName`.
- A generic-parameter use that fails to satisfy declared trait bounds.
- Using a capability name as a generic constraint, or a trait name in a `requires` row.

-----

## 7. Design decisions

|Decision                         |Choice                                                                                  |Rationale                                                                       |
|---------------------------------|----------------------------------------------------------------------------------------|--------------------------------------------------------------------------------|
|Capability conformance           |`impl Cap for Type` (trait-style)                                                       |Decouples conformance from declaration; allows post-hoc conformance.            |
|Trait conformance                |`impl Trait for Type` (same syntax)                                                     |One impl mechanism; capability vs trait distinguished by declaration.           |
|Capabilities vs traits           |Capabilities for dependencies; traits for shape                                         |Lexical resolution for deps; receiver resolution for shape.                     |
|Multiple conformance             |`+` operator                                                                            |`impl A + B for T`, `{R + Cap}`, `{R + S}`                                      |
|Composition                      |`extends`                                                                               |Authors declare hierarchy explicitly; applies to both caps and traits.          |
|Row delimiter                    |`{}` with commas                                                                        |Set-like; `+` for row extension (variable + concrete, or variable + variable).  |
|Runtime exposure                 |Twelve `io.*` capabilities (Tasks, Clock, Sleep, NetClient, NetServer, FileSystem, MemoryMap, Stdio, Signals, Process, Entropy, Sync)|Decomposed; impls declare only what they use; targets ship only what they support.|
|Concurrency model                |Runtime via `io.Tasks` capability; `Future<R, E>` and `Group<R, E>` as stdlib values    |No function coloring; runtime is a deployment choice.                           |
|`async` vs `concurrent`          |Both on `io.Tasks`; `async` permits sequential execution, `concurrent` requires overlap |Lets test runtimes implement `async` trivially; honest about hard requirements. |
|Cancellation                     |`io.Tasks.with_cancel` + `CancelToken`; `Cancelled` as row variant; `with_timeout` stdlib-derived|First-class beyond just deadlines; covers signal-driven and group-driven cancel.|
|Sync primitives                  |Factory capability `io.Sync.new_mutex/channel/...`; returns stdlib value types          |Runtime-aware; closure-form `lock` is exception-safe; test impls are trivial.   |
|Env, args, process               |`io.Process` capability                                                                 |No global `env`; production-vs-test config swap is a `provide` swap.            |
|Entropy                          |`io.Entropy` capability                                                                 |Deterministic seeding in tests via `provide` swap.                              |
|`defer` semantics                |Runs on every exit including Cancelled/Timeout/panic                                    |Resource safety under cancellation.                                             |
|Error mechanism                  |`raises` rows + `try/catch`; no `Result<T, E>`                                          |One error path; effect rows are the source of truth.                            |
|Wiring construct                 |`provide { } in { }` + Wiring values + `++` / `with`                                    |Explicit, lexically scoped, expression-valued, composable.                      |
|Scope binding                    |`@ ScopeName` mandatory on every binding                                                |No implicit defaults; scope visible at every binding site.                      |
|Lifecycle                        |`Lifecycle` trait with `start()` and `shutdown(exit)`                                   |Per scope-instance entry; `ExitReason` discriminates exit path.                 |
|Startup tie-breaking             |Lexical declaration order within `provide` block                                        |Observable; encode true dependencies via `Lifecycle.requires` when needed.      |
|Mid-startup failure              |Failed impl skips own shutdown; cleanup errors → stderr                                 |Avoids masking original error with cleanup error.                               |
|Drop                             |`Drop` trait for value cleanup                                                          |Parallel mechanism for stack values; separate from Lifecycle.                   |
|`self` parameter                 |Implicit keyword in method bodies                                                       |Java-style; mutation not visible at signature.                                  |
|`mut`                            |Binding modifier only                                                                   |No `Mut*` types; no `mut self`; simpler.                                        |
|Function type syntax             |`fn(Args) -> Return` always                                                             |One form everywhere; required leading `fn`.                                     |
|`pub` modifier                   |Functions only; controls row inference                                                  |Not a visibility mechanism in v4.                                               |
|Row inference                    |Explicit on `pub`, inferred elsewhere; exact match                                      |Catches API leakage; minimizes boilerplate.                                     |
|Capability rows in function types|Yes                                                                                     |Enables stored handlers, callbacks, job queues.                                 |
|Impl-private requires            |Allowed                                                                                 |Lets impls depend on `io.*` without leaking to callers.                         |
|Default capability/trait methods |Allowed; rule per 2.13                                                                  |Non-breaking evolution for empty-row defaults.                                  |
|Generics                         |Trait constraints only; capabilities not constraints; row params recognized by position |Caps go in `requires` rows; traits constrain types.                             |
|`Never` bottom type              |`return`, `raise`, `panic`, diverging loops                                             |Composes with `??`, `?.`, expression contexts uniformly.                        |
|`Option<T>`                      |Stdlib enum; `T?` sugar; `?.` / `??` operators                                          |One absence-handling story; not a lang item.                                    |
|Stdlib lang items                |Drop, Iterator, Eq, Ord, Hash, Display, Clone                                           |Compiler-known traits backing built-in syntax.                                  |
|Streams                          |`Stream<T>` struct + `stream { yield }`; `Iterator<T>` trait                            |Streams are values, not capabilities; iteration via trait.                      |

-----

## 8. Out of scope for v4

These are real questions deferred to future versions:

- **Module system.** The `io.X` naming pattern is opaque syntax — dots are legal in capability names, but there's no enclosing module construct, no imports, no visibility rules. Convention generalizes (`db.ReadDb`, `observability.Logger`); language support is deferred.
- **Visibility across modules.** When modules arrive, visibility rules must be defined. `pub`'s meaning may extend or get renamed.
- **First-class capability values.** v4 returns concrete impl types (e.g., `fn database_for(tid) -> Postgres`), limiting heterogeneous-impl multi-tenancy to a single backend kind. Two upgrade paths exist: (a) a `Cap<X>` first-class type with bindable values, or (b) `impl Trait`-style existential returns. Both require type-system additions around how existentials interact with `extends` subtyping, scopes, and `Lifecycle`. Deferred until a real use case forces the choice.
- **Capability conformance scope (orphan rules).** Who may write `impl ThirdPartyCap for MyType` and vice versa.
- **Generic capability inference.** How `Cache.get(key)` picks between multiple `Cache<K, V>` instantiations in scope. Nominal newtypes via `extends` are the recommended convention but not enforced.
- **`provide` for non-capability values.** Whether plain values can be bound through `provide`, or strictly capabilities.
- **Compile-error UX.** Concrete formatting and content of error messages for each failure mode. Especially important for row-unification failures and missing-capability diagnostics.
- **Variance.** All generic parameters are invariant in v4. Variance interacts with subtyping, mutation, and reference types in non-trivial ways; deferred.
- **Higher-kinded types, associated types, GATs.** Each is a substantial design exercise.
- **Reference types and borrowing.** A full reference/borrow system (`&T`, `&mut T`) is not in v4. Mutation is binding-level only.
- **Tooling.** IDE support for visualizing capability flow, scope annotations, effect rows, and closure capability surfaces.
- **Migration from existing DI frameworks.** Interop story with Spring, Dagger, etc.
- **Performance.** Monomorphization strategy, dictionary passing, zero-cost guarantee bounds. Particular concern: the `io.Sync` factory model returns values holding runtime references — how the compiler eliminates the indirection when only one `io.Sync` impl is active is an open question.
- **Stack traces across suspension points.** Each `io.Tasks` impl must provide good debugging affordances.
- **Closure capability surface.** Closures that escape their lexical context carry inferred `requires` rows. This can produce surprising couplings in non-trivial closures. Inference is preserved; lint-level tooling that visualizes closure rows is the suggested mitigation.
- **Error promotion ergonomics.** Repeated `try X catch DbError(e) -> raise DbFailure(e)` re-tagging is verbose by design. No language sugar; libraries may address it.
- **Signature bloat.** v1's flagged `requires`-row length issue (controllers reaching 10-14 capabilities) remains unaddressed at the language level. `bundle` was considered and rejected as undermining the "dependencies visible in the signature" property. Future mechanisms (capability supersets via `extends`, IDE folding, module-level implicit-requires) all have their own problems; the question stays open. The v4 io decomposition makes this worse before it makes it better — fully-wired servers list twelve `io.*` bindings — but the cost lands at `main`, not in every function signature.
- **Framework-side per-request scope entry.** §2.11 describes `provide @ Request` re-entry as "the framework exposes this as a hook." A standard primitive for "cleanly enter a fresh scope per iteration with proper Lifecycle handling" would let frameworks compose. Currently each framework reinvents this.
- **Per-scope-instance Lifecycle for transient scopes.** Request and Transaction scopes can have many concurrent instances. `Lifecycle.start`/`shutdown` semantics for these are specified per-entry (§2.10) but the runtime cost and concurrency story is not pinned down.

-----

## 9. Changes from v3

This section catalogs differences from v3 (`capability-language-design-v3.md`). Anything not listed here is unchanged.

**Runtime decomposition (the headline change):**

1. **The four `io.*` capabilities become twelve.** v3's `io.Execution` bundled scheduling, sleep, deadline cancellation, and network client primitives into one capability — meaning a Logger that only writes to a socket transitively pulled in `spawn` and `with_timeout`. v4 splits this surface into:
    - `io.Tasks` — scheduling, `async`/`concurrent`, `yield_now`, `with_cancel`
    - `io.Sleep` — `sleep`, `remaining`
    - `io.NetClient` — `connect`, `read`, `write`, `close` (client-side)
    - `io.NetServer` — `bind`, `accept`, `close` (server-side; **new** — v3 had no server capability)
   And `io.StdStreams` → `io.Stdio` (now includes stdin).
   And four entirely new capabilities: `io.MemoryMap`, `io.Process`, `io.Entropy`, `io.Sync`.
1. **Server networking added.** v3 had `connect`/`read`/`write` only. v4 adds `bind`/`accept`/`Listener` on `io.NetServer`. You could not write an HTTP server in v3.
1. **`io.Sync` factory capability for runtime-aware sync primitives.** `Mutex<T>`, `Channel<T>`, `Condvar`, `Semaphore` are created via `io.Sync.new_*` and carry hidden runtime references. The closure form `Mutex.lock(|x| ...)` is the canonical API.
1. **`io.Process` for environment, args, and subprocesses.** v3 examples used `env.DB_URL` with no defined source. v4 makes config access an explicit `io.Process.env(...)` call.
1. **`io.Entropy` for randomness.** Crypto, ID generation, and jittered backoff declare it; tests bind `SeededRng(seed)`.
1. **`io.Clock` split from `io.Sleep`.** Reading wall time and blocking on time are different concerns with different impl swap stories.

**Concurrency primitives (mostly new):**

1. **`Future<R, E>` and `Group<R, E>` as stdlib value types.** Replace v3's mentioned-but-undefined `JoinHandle<Unit>`. Both carry rows of raises variants. `Future.cancel` is trip-and-wait. `Group.cancel` drains then fails. Heavily informed by Zig's `std.Io` shape.
1. **`async` vs `concurrent` distinction.** `async` may run sequentially under restrictive runtimes; `concurrent` requires true overlap. Matches Zig's distinction and lets test runtimes implement `async` trivially.
1. **`select` syntax for multi-future blocking.** First-arm-to-fire wins; others are not implicitly cancelled.
1. **`with_cancel` as the cancellation primitive; `Cancelled` as a row variant.** v3 had only `with_timeout` and a `Timeout` variant — adequate for deadlines, unable to express "stop because of an external signal." v4 makes external cancellation first-class.
1. **`with_timeout` becomes stdlib-derived,** not a primitive. It composes from `with_cancel` plus an `io.Sleep` timer task that trips the token.
1. **`uncancellable { ... }` block** for critical sections that must not be interrupted mid-protocol.

**Type-system additions:**

1. **Row + row composition.** `{R + S}` for two row variables (v3 only specified `{R + Cap}` — row variable plus concrete). Required by generic types like `Router<R>` that accumulate rows from heterogeneous handlers.
1. **Row parameters explicitly recognized.** Generic parameters appearing in row position (`requires {R}`, `raises {E}`) are row variables. v3 used this in examples (`Handler<R>`) without specifying it.

**Lifecycle clarification:**

1. **Startup tie-breaking specified as lexical declaration order.** v3 specified topological order but left ties unspecified. v4 pins it down: siblings start in declaration order, shut down in reverse — observable, and necessary for getting drain-before-close orderings right without spurious dependencies.

**Knock-on renames in worked examples and prose:**

- `io.Execution.spawn` → `io.Tasks.async` or `.concurrent`
- `io.Execution.with_timeout` → stdlib `with_timeout` (derived)
- `io.Execution.sleep` → `io.Sleep.sleep`
- `io.Execution.connect`/`read`/`write`/`close` → `io.NetClient.*`
- `io.StdStreams` → `io.Stdio`
- `env.X` references → `io.Process.env("X")` with caller declaring `requires {io.Process}`
- The Postgres example's `requires {io.Execution, Logger}` becomes `requires {io.NetClient, io.Sleep, Logger}`

**Deferred items in v3 now resolved:**

- Cancellation beyond deadlines — resolved by `with_cancel`/`CancelToken` and `Cancelled` row variant.
- Server-side networking — resolved by `io.NetServer`.
- Row + row composition — resolved in §2.3.
- Lifecycle tie-breaking — resolved in §2.10.
- `JoinHandle` surface — resolved by replacing with `Future<R, E>`.

**Deliberately not changed:**

- The "every binding carries `@ ScopeName`" rule from v3.
- The "no `?` or `from` for error promotion" position; the verbose form keeps boundaries visible.
- The "no `Result<T, E>`" position; errors flow only through `raises`.
- The "capabilities aren't generic constraints" rule.
- `Wiring` composition operators (`++`, `with`).
- `Drop` and `Lifecycle` as separate mechanisms with the `provide`-binding boundary.
- Streams as values implementing `Iterator<T>`, not capabilities.

**Carried forward unchanged from v3:**

- All capability/effect-row machinery (impl-private requires, row variables, `extends` subtyping, lexical resolution).
- Default methods on capabilities and traits.
- Named scopes with `@` annotations.
- `defer` runs on every exit path (now including `Cancelled` explicitly).
- Construction-order discipline within `provide` blocks (forward references rejected).
- `Never` bottom type, `Option<T>`, `?.` and `??` operators.
- Stdlib lang items inventory (Drop, Iterator, Eq, Ord, Hash, Display, Clone).
