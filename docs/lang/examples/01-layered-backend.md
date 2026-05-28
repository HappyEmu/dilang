# Example: Layered backend service

A small task-tracker HTTP service in the classic layered style: controllers call services, services call repositories, repositories call the database. Each layer is a capability; wiring happens at `main`; tests swap in-memory implementations.

This example exercises: capability declarations, impl-private requires, effect rows on functions, the `IO` capability (for socket, time, env), middleware via row polymorphism, request-scoped capabilities, transactions via `Lifecycle`, error re-tagging at boundaries, and composable `Wiring` values for tests.

For language concepts, see [../design.md](../design.md). For syntax, see [../syntax.md](../syntax.md).

-----

## 1. Domain

```di
struct User { id: Uuid, email: Email, name: Str }
struct Task { id: Uuid, owner: Uuid, title: Str, done: Bool, created_at: Instant }
struct CreateTaskInput { title: Str }

enum AppError {
    NotFound
    Forbidden
    BadInput(reason: Str)
    DbFailure(DbError)
}
```

-----

## 2. Capabilities

### 2.1 Cross-cutting infrastructure

```di
capability Logger {
    fn info(msg: Str, fields: Map<Str, Json> = {})
    fn warn(msg: Str, fields: Map<Str, Json> = {})
    fn error(msg: Str, err: Error, fields: Map<Str, Json> = {})
}

capability Clock @ 'Process { fn now() -> Instant }
capability IdGen @ 'Process { fn next() -> Uuid }
```

### 2.2 Database

```di
capability ReadDb {
    fn query(sql: Sql) -> Rows raises {DbError}
}

capability WriteDb extends ReadDb {
    fn execute(sql: Sql) raises {DbError}
    fn acquire() -> Connection                // for transaction scope
}
```

### 2.3 Repositories

The repository layer hides SQL from the service layer.

```di
capability TaskRepo {
    fn find(id: Uuid) -> Task?            raises {DbFailure}
    fn list_for(owner: Uuid) -> List<Task> raises {DbFailure}
    fn insert(task: Task)                  raises {DbFailure}
    fn update(task: Task)                  raises {DbFailure}
    fn delete(id: Uuid)                    raises {DbFailure}
}

capability UserRepo {
    fn find(id: Uuid) -> User? raises {DbFailure}
}
```

### 2.4 Request context

```di
capability RequestCtx @ 'Request {
    fn request_id() -> Uuid
    fn current_user() -> User?
}
```

-----

## 3. Repository implementations

The repository impl translates capability calls into SQL. It declares `WriteDb` as a private dependency — callers see only `requires {TaskRepo}`.

```di
struct PgTaskRepo {}

impl TaskRepo for PgTaskRepo {
    requires {WriteDb}

    fn find(id: Uuid) -> Task? raises {DbFailure} {
        try WriteDb.query(sql"SELECT * FROM tasks WHERE id = ${id}")
            .first()
            .map(Task.from_row)
        catch DbError(e) -> raise DbFailure(e)
    }

    fn list_for(owner: Uuid) -> List<Task> raises {DbFailure} {
        try WriteDb.query(sql"SELECT * FROM tasks WHERE owner = ${owner}")
            .all()
            .map(Task.from_row)
        catch DbError(e) -> raise DbFailure(e)
    }

    fn insert(task: Task) raises {DbFailure} {
        try WriteDb.execute(sql"INSERT INTO tasks (id, owner, title, done, created_at)
                                VALUES (${task.id}, ${task.owner}, ${task.title},
                                        ${task.done}, ${task.created_at})")
        catch DbError(e) -> raise DbFailure(e)
    }

    fn update(task: Task) raises {DbFailure} { /* ... */ }
    fn delete(id: Uuid)   raises {DbFailure} { /* ... */ }
}
```

The error re-tag from `DbError` (a low-level SQL error) to `DbFailure` (a domain error) happens at this boundary. The service layer above does not know about `DbError`.

An in-memory impl for tests:

```di
struct InMemoryTaskRepo { tasks: Mutex<Map<Uuid, Task>> }

impl TaskRepo for InMemoryTaskRepo {
    requires {IO}        // for the Mutex (sync primitive)

    fn find(id: Uuid) -> Task? raises {DbFailure} {
        self.tasks.lock(|m| m.get(id))
    }
    // ... other methods analogous ...
}
```

-----

## 4. Service layer

The service layer orchestrates repositories and applies business rules. It declares the repositories it uses, not the database directly.

```di
pub fn create_task(owner: Uuid, input: CreateTaskInput) -> Task
    requires {TaskRepo, UserRepo, Logger, Clock, IdGen}
    raises   {BadInput, NotFound, DbFailure}
{
    if input.title.trim().is_empty() {
        raise BadInput("title is required")
    }

    // Owner must exist
    UserRepo.find(owner) ?? raise NotFound

    let task = Task {
        id: IdGen.next(),
        owner,
        title: input.title.trim(),
        done: false,
        created_at: Clock.now(),
    }
    TaskRepo.insert(task)
    Logger.info("task created", {"task_id": task.id, "owner": owner})
    task
}

pub fn list_tasks(owner: Uuid) -> List<Task>
    requires {TaskRepo}
    raises   {DbFailure}
{
    TaskRepo.list_for(owner)
}

pub fn complete_task(id: Uuid, by: Uuid) -> Task
    requires {TaskRepo, Logger, Clock}
    raises   {NotFound, Forbidden, DbFailure}
{
    let task = TaskRepo.find(id) ?? raise NotFound
    if task.owner != by { raise Forbidden }

    let updated = Task { ...task, done: true }
    TaskRepo.update(updated)
    Logger.info("task completed", {"task_id": id})
    updated
}
```

Note what is *not* in these signatures: no `WriteDb`, no `IO`, no SQL types. The service is testable with a `Map`-backed `TaskRepo` and a `FixedClock` without touching any I/O.

-----

## 5. Middleware

Middleware is just a function that takes a handler and returns a handler. Row polymorphism lets one middleware wrap any handler regardless of its underlying dependencies.

### 5.1 Request logging

```di
fn with_request_logging<R, E>(
    handler: fn() -> Response requires {R} raises {E}
) -> Response
    requires {R, Logger, Clock, RequestCtx}
    raises   {E}
{
    let start = Clock.now()
    let id = RequestCtx.request_id()
    Logger.info("→", {"request_id": id})
    let res = handler()
    Logger.info("←", {"request_id": id, "status": res.status,
                      "ms": (Clock.now() - start).as_millis()})
    res
}
```

The `R` parameter is a row variable; the middleware accepts any handler row and forwards it through its own row.

### 5.2 Authentication

```di
fn with_auth<R, E>(
    req: Request,
    handler: fn() -> Response requires {R + RequestCtx} raises {E}
) -> Response
    requires {R, UserRepo, TokenSigner, RequestCtx}
    raises   {E}
{
    let token = req.header("Authorization")?.strip_prefix("Bearer ")
        ?? return Response.unauthorized()
    let claims = TokenSigner.verify(token) ?? return Response.unauthorized()
    let user = try UserRepo.find(claims.sub)
        catch DbFailure(_) -> return Response.server_error()
    let user = user ?? return Response.unauthorized()

    with [RequestCtx <- RequestCtx.with_user(user)] @ 'Request {
        handler()
    }
}
```

The handler's row gains `RequestCtx` because `with_auth` re-binds it; the binding makes `current_user()` reflect the authenticated user.

-----

## 6. Controllers (HTTP handlers)

```di
fn create_task_handler(req: Request) -> Response
    requires {TaskRepo, UserRepo, Logger, Clock, IdGen, RequestCtx}
    raises   {}
{
    let user = RequestCtx.current_user() ?? return Response.unauthorized()
    let input = try req.json_body<CreateTaskInput>()
        catch ParseError(_) -> return Response.bad_request("invalid body")

    try {
        let task = create_task(user.id, input)
        Response.created(task)
    } catch {
        BadInput(reason) -> Response.bad_request(reason)
        NotFound         -> Response.not_found()
        DbFailure(e)     -> { Logger.error("db", e); Response.server_error() }
    }
}

fn list_tasks_handler(req: Request) -> Response
    requires {TaskRepo, Logger, RequestCtx}
    raises   {}
{
    let user = RequestCtx.current_user() ?? return Response.unauthorized()
    try Response.ok(list_tasks(user.id))
    catch DbFailure(e) -> { Logger.error("db", e); Response.server_error() }
}
```

The controller signature is the longest in the system — that is by design. Pull-down everything the request needs to be handled, and the row tells you exactly what those things are.

-----

## 7. Router

```di
fn router() -> Router<{TaskRepo, UserRepo, TokenSigner, Logger, Clock,
                        IdGen, RequestCtx}>
{
    Router.new()
        .post("/tasks",         create_task_handler)
        .get ("/tasks",         list_tasks_handler)
        .post("/tasks/:id/done", complete_task_handler)
}
```

`Router<R>` accumulates handler rows via the generic row union (see syntax §8.4). The router's row is the union of all registered handlers' rows.

-----

## 8. Wiring at main

```di
fn main() {
    let rt = FiberRuntime(workers: 8)

    with [
        IO          <- rt
        Logger      <- JsonLogger()
        Clock       <- SystemClock()
        IdGen       <- UuidV7Gen()
        WriteDb     <- Postgres(IO.env("DB_URL") ?? "")
        TaskRepo    <- PgTaskRepo {}
        UserRepo    <- PgUserRepo {}
        TokenSigner <- Hs256Signer(IO.env("JWT_SECRET")
                                   ?? panic("JWT_SECRET"))
    ] @ 'Process {
        serve(8080, router())
    }
}
```

`IO.env(...)` is an explicit capability call; there is no global `env` accessor. The order of bindings matters: `TaskRepo` depends on `WriteDb` being already bound (see syntax §7.1).

-----

## 9. Server with graceful shutdown

```di
pub fn serve<R>(port: U16, router: Router<R>)
    requires {R, IO, Logger}
    raises   {IoError}
{
    let listener = IO.bind(SocketAddr.any(port))
    defer IO.close(listener)
    Logger.info("listening", {"port": port})

    let inflight: Group<Unit, Never> = Group.new()

    // Signal-watcher closes the listener to break the accept loop
    IO.spawn(|| {
        let sig = IO.wait_for_signal([Signal.TERM, Signal.INT])
        Logger.info("shutdown signal", {"signal": sig})
        IO.close(listener)
    })

    loop {
        let sock = try IO.accept(listener)
                   catch IoError(_) -> break
        inflight.concurrent(|| handle_conn(sock, router))
    }

    try with_timeout(30.seconds) { inflight.await() }
    catch Timeout -> Logger.warn("drain incomplete; remaining handlers cancelled")
}

fn handle_conn<R>(sock: Socket, router: Router<R>)
    requires {R, IO, Logger}
{
    defer IO.close(sock)
    try with_timeout(30.seconds) {
        let req = read_request(sock)
        with [RequestCtx <- RequestCtx.fresh(req)] @ 'Request {
            let resp = with_request_logging(||
                with_auth(req, ||
                    router.dispatch(req).unwrap_or(Response.not_found())))
            write_response(sock, resp)
        }
    } catch {
        Timeout    -> Logger.warn("request timeout")
        IoError(e) -> Logger.warn("connection error", {"err": e})
    }
}
```

The accept loop is plain `loop { ... }`. No async/await colors any function. The `Group<Unit, Never>` tracks in-flight connections; the `defer` on the listener and on the socket guarantee cleanup regardless of how each scope exits.

-----

## 10. Transactions

A transaction is a `Transaction`-scoped capability whose `Lifecycle` issues `BEGIN`/`COMMIT`/`ROLLBACK`.

```di
capability DbTx @ 'Transaction {
    fn execute(sql: Sql) raises {DbError}
    fn query(sql: Sql) -> Rows raises {DbError}
}

struct PgTransaction { conn: Connection }

impl DbTx for PgTransaction {
    fn execute(sql: Sql) raises {DbError} { self.conn.execute(sql) }
    fn query(sql: Sql) -> Rows raises {DbError} { self.conn.query(sql) }
}

impl Lifecycle for PgTransaction {
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
```

Used like this:

```di
pub fn transfer_tasks(from: Uuid, to: Uuid)
    requires {WriteDb, Logger}
    raises   {DbFailure}
{
    with [DbTx <- PgTransaction { conn: WriteDb.acquire() }] @ 'Transaction {
        try {
            DbTx.execute(sql"UPDATE tasks SET owner = ${to} WHERE owner = ${from}")
            DbTx.execute(sql"INSERT INTO audit (event) VALUES ('transfer')")
            // Block exits normally → COMMIT runs via Lifecycle.shutdown(Normal)
        } catch DbError(e) -> raise DbFailure(e)
        // Re-raise → ROLLBACK runs via Lifecycle.shutdown(Raised(_))
    }
}
```

No `BEGIN` / `COMMIT` / `ROLLBACK` keywords. No transaction macro. The shape is the same as every other scoped capability.

-----

## 11. Tests

Test setup defines reusable `Wiring` values and spreads them with `...`.

```di
fn test_runtime() -> Wiring {
    with [
        IO     <- TestIO()                                          @ 'Process
        Logger <- TestLogger()                                      @ 'Process
        Clock  <- FixedClock(Instant.parse("2026-05-22T12:00:00Z")) @ 'Process
        IdGen  <- SeqIdGen([Uuid.parse("t1"), Uuid.parse("t2")])    @ 'Process
    ]
}

fn test_repos() -> Wiring {
    let users = InMemoryUserRepo()
    users.insert(User { id: Uuid.parse("u1"), email: "a@b", name: "Alice" })
    with [
        TaskRepo <- InMemoryTaskRepo() @ 'Process
        UserRepo <- users              @ 'Process
    ]
}

test "create_task persists with current clock and id" {
    with [
        ...test_runtime(), ...test_repos(),
    ] @ 'Process {
        let task = create_task(Uuid.parse("u1"), CreateTaskInput { title: "buy milk" })
        assert task.title == "buy milk"
        assert task.id == Uuid.parse("t1")
        assert task.created_at == Instant.parse("2026-05-22T12:00:00Z")
    }
}

test "create_task rejects empty title" {
    with [
        ...test_runtime(), ...test_repos(),
    ] @ 'Process {
        try create_task(Uuid.parse("u1"), CreateTaskInput { title: "  " }) catch {
            BadInput(reason) -> assert reason == "title is required"
            other            -> assert false, "unexpected: ${other}"
        }
    }
}

test "create_task fails when owner does not exist" {
    with [
        ...test_runtime(), ...test_repos(),
        UserRepo <- InMemoryUserRepo(),    // overrides test_repos()'s populated UserRepo
    ] @ 'Process {
        try create_task(Uuid.parse("u999"), CreateTaskInput { title: "x" }) catch {
            NotFound -> {}
            other    -> assert false, "expected NotFound, got ${other}"
        }
    }
}
```

The production code is reused unchanged in tests. The `IO` impl is a deterministic test runtime; the database is a `Map`; ids and time are deterministic. No mocking framework. No fixture inheritance. Overrides are just bindings placed after the spread entries they shadow.

-----

## 12. What this example demonstrates

| Feature                                 | Where                                                |
|-----------------------------------------|------------------------------------------------------|
| Capability declaration                  | §2 (`Logger`, `ReadDb`, `TaskRepo`, `RequestCtx`)    |
| Capability extension                    | `WriteDb extends ReadDb` (§2.2)                      |
| Impl-private requires                   | `PgTaskRepo` declares `WriteDb` privately (§3)       |
| Error re-tagging at boundary            | Repo catches `DbError`, raises `DbFailure` (§3)      |
| Effect rows on services                 | `create_task` lists `{TaskRepo, UserRepo, ...}` (§4) |
| Row-polymorphic middleware              | `with_request_logging<R, E>` (§5)                    |
| Request-scoped capability re-binding    | `with_auth` rebinds `RequestCtx` (§5.2)              |
| `IO` capability (single, like Zig)      | `IO.env`, `IO.bind`, `IO.spawn`, `IO.wait_for_signal`|
| `with` at `main`                        | §8                                                   |
| Graceful shutdown with `Group`          | §9                                                   |
| `defer` on every exit                   | §9 (listener, socket)                                |
| `with_timeout` derived from cancel      | §9 (drain timeout)                                   |
| Transactions via scope + Lifecycle      | §10                                                  |
| `Wiring` composition for tests          | §11 (`...` + lexical override)                       |
| Deterministic test runtime              | §11                                                  |
