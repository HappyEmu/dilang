# RFC-002 — Visible error propagation (`try` at every fallible call)

Status: Proposed.

This RFC makes error propagation visible at the use site. Today a fallible call
propagates its errors silently — the only signal is the callee's signature and
the enclosing function's `raises` row:

```di
pub fn lookup_user(id: Uuid) -> User
    requires {Database}
    raises   {DbError}
{
    Database.query(sql"SELECT * FROM users WHERE id = ${id}")   // can fail — nothing says so
        .first()
        .map(User.from_row)
        ?? raise NotFound                                        // this escape *is* visible
}
```

A reviewer cannot tell which line transfers control to the caller without
opening `Database.query`. This RFC closes that gap by borrowing Zig's call-site
`try`: a fallible operation is prefixed with `try`, and a reviewer reconstructs
a function's entire error control-flow from two tokens — `try` and `raise` —
without reading a single callee signature. It also keeps propagation in the
language's straight-line form — a column of `let` bindings read top to bottom —
rather than the nested combinator chains a `Result`-returning model invites. That
property is the design goal this whole shape serves — design §2.11 (control flow
is linear); §3.6 below records how this RFC implements it.

This builds on, and is consistent with, **DEC-006** (no `?`/`from`: error
boundaries must be visible). `?` was rejected because it hides the *conversion*
at a domain boundary. `try` is the opposite move: it makes *propagation* loud.
The two decisions share one goal — keep error edges on the page.

-----

## 1. Summary of changes

### 1.1 `try` prefixes every fallible call

A call whose `raises` row is non-empty must be prefixed with `try`. A call with
an empty `raises` row must **not** be (over-marking is an error, symmetric with
the over/under-declaration rule for rows, design §4.1.2).

```di
let user = try Database.lookup(req.id)      // fallible → try required
let name = render(user.profile)             // infallible → no try
```

`try` is a prefix operator that binds to a single call expression. In a chain or
nested expression, its position pins the exact fallible call:

```di
try send_report(try render_summary(try Database.query(sql)))
//  └ send       └ render            └ query
```

Three `try`s, three calls that can fail, innermost-first. An unmarked call in
that expression is one that provably cannot fail.

### 1.2 `try` targets the nearest enclosing `catch`

`try` does **not** mean "escapes the function." It means:

> On failure, control jumps to the **nearest enclosing `catch`**; if there is
> none, it leaves the function.

So a fallible call keeps its `try` even when a handler two lines down will catch
it — the marker describes the call, not its eventual fate. This is what lets a
reviewer see *which* statement in a handled block is the fallible one.

### 1.3 Block handlers: `{ ... } catch { ... }`

A `catch` attaches to a block as readily as to an expression. The fallible
statements inside carry their own `try` (they jump to that catch); an infallible
statement carries none:

```di
let report = {
    let user  = try Database.lookup(req.id)     // ─┐
    let prefs = try FileSystem.read(user.path)  //  ├─ jump here on failure
    let live  = try HttpClient.get(prefs.url)   // ─┘
    build_report(user, prefs, live)             // no try → cannot fail
} catch {
    DbError(e)  -> Report.stale("db")
    IoError(e)  -> Report.stale("fs")
    NetError(e) -> Report.stale("net")
}
```

The `catch` clause alone could not tell a reviewer which of the four lines is
fallible. The inner `try`s do. This is the central reason the marker lives on
the call and not on the handler.

### 1.4 No silent fall-through; propagate with an explicit `raise`

A `catch` must be **exhaustive** over the `try`-marked errors that reach it. The
only way an error continues past a `catch` is an explicit `raise` arm:

```di
let rows = try Database.query(sql) catch {
    DbError.Timeout(e) -> Rows.empty()      // handled here
    DbError(e)         -> raise e           // forwarded — visibly
}
```

This tightens syntax.md §6.2, which currently lets uncaught variants escape
silently as long as the enclosing function re-declares them. That allowance is
exactly the invisible propagation this RFC removes. To handle one variant and
forward the rest, write a catch-all forwarding arm:

```di
... catch {
    DbError.Timeout(e) -> retry()
    _ -> raise                              // re-raise whatever else it was
}
```

Because all propagation past a handler is an explicit `raise`, a catch-construct
(expression *or* block) **never** needs a leading `try` of its own. Its potential
escape is always marked by a `raise` token inside an arm.

### 1.5 Two escape tokens, and an `errdefer` companion

After this RFC, every edge by which control leaves a function via the error path
is one of exactly two tokens:

- `try` — a fallible leaf operation (a jump *originates* here).
- `raise` — an error is *created or forwarded* here.

Scanning for `try` and `raise` enumerates the complete error control-flow. This
also gives `errdefer` (the open half of **DEC-011**) a precise meaning: cleanup
that runs only when control leaves the block by one of those edges.

```di
let conn = try pool.acquire()
errdefer conn.discard()      // runs only on an escape below; not on the success path
try conn.write(frame)        // if this escapes, conn is discarded
conn.release()
```

-----

## 2. Syntax reference

```di
try call(args)                       // fallible leaf; jumps to nearest catch / caller
try recv.method(args)                // method form
(try call(args)).pure_method()       // try binds to the inner call only

try EXPR catch { arms }              // expression handler
{ stmts } catch { arms }             // block handler

... catch {
    Variant(binding) -> handler_expr
    Variant           -> handler_expr
    _                 -> raise        // forward the rest
}
```

Rules:

1. A call with a non-empty `raises` row **must** be prefixed with `try`. A call
   with an empty `raises` row **must not** be. Both violations are compile
   errors (symmetric with row over/under-declaration, design §4.1.2).
2. `try` binds to a single call expression. To mark a fallible call that is the
   receiver or an argument of a larger expression, parenthesize:
   `(try a()).b()`, `f(try g())`.
3. On failure, a `try`-marked call transfers control to the nearest lexically
   enclosing `catch`. If none encloses it, the error leaves the function, and
   the function's declared `raises` row must contain it (design §4.1.4).
4. `catch` attaches to either a single expression (`try EXPR catch {…}`) or a
   block (`{…} catch {…}`). In both, the fallible operations inside retain their
   own `try`.
5. A `catch` must be exhaustive over the errors that reach it. There is no
   silent fall-through.
6. The only way an error continues past a `catch` is an explicit `raise` arm
   (re-raise identical, re-tag, or originate a new error). The `raise` is the
   visible escape marker; a catch-construct therefore never takes a leading
   `try`.
7. `raise` and `try` are the only two tokens that begin an error escape edge.
8. `errdefer { … }` runs on exit from its block via a `try` or `raise` escape,
   not on normal completion. (Companion to DEC-011; see Open Questions.)

-----

## 3. Why this shape

### 3.1 The marker is on the call, not the handler

Rejected: `try` means "escapes the enclosing function," so a fully-handled call
drops its marker.

```di
// rejected model
let report = {
    let user  = Database.lookup(req.id)     // no try — but which of these
    let prefs = FileSystem.read(user.path)  // three can fail? the reviewer
    let live  = HttpClient.get(prefs.url)   // is back to reading signatures
    build_report(user, prefs, live)
} catch { /* ... */ }
```

This re-hides fallibility precisely inside handling blocks — the place a
reviewer most wants to see it. Binding the marker to the call instead keeps the
property everywhere a `catch` appears.

### 3.2 No silent fall-through

Rejected: keep §6.2's allowance that uncaught variants propagate when the
enclosing function re-declares them.

Silent fall-through is invisible propagation with extra steps — the exact thing
this RFC exists to remove. Requiring an explicit `raise` arm costs one line per
forwarded group and keeps every escape on the page. Given the premise ("the
reviewer should not have to cross-reference the signature"), that line earns its
keep.

### 3.3 No leading `try` on catch-constructs

Rejected: mark a catch-expression or block that can still escape with an outer
`try`, e.g. `try { … } catch { partial }`.

Once propagation past a handler is always an explicit `raise` (§3.2), the escape
is already marked by that `raise`. A second marker on the construct would be
redundant, and it would reintroduce the ambiguity of "which variant escapes"
that the per-arm `raise` resolves cleanly.

### 3.4 `try` binds tight, even at the cost of parens

Rejected: `try` as a low-precedence operator covering a whole expression.

A whole-expression `try expr` cannot say *which* sub-call is the fallible one —
the entire point. Binding `try` to a single call preserves that, at the cost of
parentheses when a fallible call sits mid-chain (`(try query()).first()`). The
recommended idiom avoids the parens by giving the fallible step its own line —
which is the more reviewable shape regardless:

```di
let rows = try Database.query(sql)
let user = rows.first().map(User.from_row) ?? raise NotFound
```

### 3.5 Consistency with DEC-006

`?` was rejected for hiding the conversion at a domain boundary. `try` is its
mirror: it hides nothing and forces a marker at every propagation site. The two
decisions are the same principle — error edges are visible — applied to the two
halves (conversion, propagation).

### 3.6 Linear flow, not chained flow

This RFC is one implementation of design §2.11 (control flow is linear); that
principle is the value the rest of this shape serves. A `try`-marked call returns
the success value *directly* — `try f()` has type `T`, not `Result<T, E>`. There
is no wrapper to unwrap, so each step is an ordinary `let` binding and the next
step uses the result by name:

```di
let user  = try Database.lookup(req.id)
let prefs = try FileSystem.read(user.path)
let live  = try HttpClient.get(prefs.url)
```

The program reads top to bottom as a sequence of named steps. Data flows through
named locals; the failure edge is a leading token on the line, not a change in
structure. Each line is legible on its own.

Rejected: monadic chaining as the propagation idiom.

```di
Database.lookup(req.id)
    .and_then(|user|  FileSystem.read(user.path)
    .and_then(|prefs| HttpClient.get(prefs.url)
    .and_then(|live|  build(user, prefs, live))))
```

Here the happy path is buried in nested closure bodies, control flow is encoded
in combinator names instead of statements, and the intermediate values are
anonymous parameters introduced right-to-left. That is the shape a
`Result`-returning model pushes you toward; it is the shape this language
rejects. The row-based error model — no `Result` to thread — is precisely what
makes the straight-line form the path of least resistance rather than something
the writer has to reach for.

This is design §2.11 in force: the reader scans a column of `let`s and a column
of `try`s, not a tree of closures. Where a fallible call would otherwise sit
mid-chain, the recommended idiom (§3.4) is to give it its own `let` line — not
merely to avoid parentheses, but because the linear shape is the goal. This is a
default, not a prohibition: §2.11.3 leaves room for a dedicated chaining form for
the cases where a name would be pure ceremony, and that form (deferred) would
compose with `try` the same way — the marker still sits on each fallible call.

-----

## 4. Migration

### 4.1 `lookup_user` (syntax.md §1.1)

The current example has an unmarked fallible call and an inconsistent row
(`Database.query` raises `DbError`, but the function declared only `{NotFound}`).
After this RFC the fallible call is marked and the row is honest:

```di
pub fn lookup_user(id: Uuid) -> User
    requires {Database}
    raises   {NotFound}
{
    let rows = try Database.query(sql"SELECT * FROM users WHERE id = ${id}")
        catch DbError(e) -> raise NotFound          // re-tag at the boundary
    rows.first().map(User.from_row) ?? raise NotFound
}
```

### 4.2 Transaction block (RFC-001 §4.3)

The transfer example used a block `try … catch` with unmarked statements inside.
After this RFC the two writes carry `try`:

```di
fn transfer(req: TransferRequest) -> Receipt
    requires {WriteDb}
    raises   {DbFailure}
= with [
    DbTx <- PgTransaction { conn: WriteDb.acquire() }
] @ 'Transaction {
    {
        try DbTx.execute(sql"UPDATE accounts SET balance = balance - ${req.amount}")
        try DbTx.execute(sql"UPDATE accounts SET balance = balance + ${req.amount}")
        Receipt { id: DbTx.last_id() }
    } catch DbError(e) -> raise DbFailure(e)
}
```

### 4.3 `LicensedCrm` (RFC-001 §5.1)

Already aligned — that example marks each fallible call (`try LicenseRepo…`,
`try HttpClient…`) and forwards via `raise` in the catch arm. It is the model
this RFC generalizes.

-----

## 5. Showcase examples

### 5.1 A run of fallible calls, all escaping

```di
fn process(req: Request) -> Output
    requires {Database, FileSystem, HttpClient}
    raises   {DbError, IoError, NetError}
{
    let user = try Database.lookup(req.id)
    let file = try FileSystem.read(user.path)
    let resp = try HttpClient.post(file)
    Output { body: resp }
}
```

Three escape points, read off the `try`s; `raises` is their union.

### 5.2 Chain where only one link fails

```di
let user = (try Database.query(sql)).first().map(User.from_row) ?? raise NotFound
```

`query` can fail; `first` and `map` cannot; `?? raise NotFound` is a second,
visible escape.

### 5.3 Loop: propagate-out vs. handle-and-continue

```di
// bail the whole function on the first failure
for url in urls {
    let body = try HttpClient.get(url)
    process(body)
}

// skip failures, keep going — fully handled, so no escape leaves the loop
for url in urls {
    let body = HttpClient.get(url) catch {
        NetError(e) -> { Logger.warn("skip ${url}", e); continue }
    }
    process(body)
}
```

Structurally identical lines; the presence of `try` tells the reviewer whether
one bad URL aborts the batch.

### 5.4 Nested blocks resolve to the nearest catch

```di
let out = {
    let cfg  = try load_config()                  // ── jumps to OUTER catch
    let data = {
        let raw = try FileSystem.read(cfg.path)   // ─┐ jumps to INNER catch
        try parse(raw)                            // ─┘
    } catch {
        IoError(e)    -> Bytes.empty()            // handled at inner
        ParseError(e) -> raise ConfigError(e)     // forwarded → travels to OUTER
    }
    finalize(cfg, data)                           // no try → cannot fail
} catch {
    LoadError(e)   -> Out.default()
    ConfigError(e) -> Out.default()
}
```

Traced with tokens alone: `read`/`parse` jump to the inner catch; `load_config`
skips it and jumps to the outer; the inner `ParseError` arm `raise`s
`ConfigError`, which the `raise` shows escaping the inner block to the outer
catch; `finalize` is provably infallible.

### 5.5 Error and absence are independent axes

```di
let cfg = try parse_config(Cache.get("cfg") ?? try FileSystem.read("cfg.toml"))
```

`Cache.get` is infallible but optional (`??`); on a miss, `try FileSystem.read`
can fail; `try parse_config` can fail. Two error escapes, one absence-fallback,
none masquerading as the other.

-----

## 6. Parser and typechecker impact

1. Lexer: `try` and `errdefer` keywords (`try` already exists for the current
   `try … catch`; the change is grammatical, not lexical).
2. Parser: `try` becomes a prefix operator on a call expression, usable without
   a trailing `catch`. `catch` attaches to a block as well as an expression.
3. AST: a `Try` node wrapping a call; `catch` arms grow a required-exhaustive
   check; an `errdefer` node parallel to `defer`.
4. Typechecker (the enforcing pass): the `try`-required / `try`-forbidden rule
   (§2 rule 1) needs each call's `raises` row, so enforcement lands with the
   typechecker — same dependency as DEC-010. Until then, the interpreter may
   parse `try` permissively and defer the biconditional check.
5. Exhaustiveness: `catch` arm checking must reject non-exhaustive handlers that
   lack a forwarding `raise` arm (tightening of §6.2).

-----

## 7. Open questions

1. **Forwarding-arm sugar.** Is `_ -> raise` (re-raise the unhandled remainder
   identically) the right spelling, and does a bare `raise` with no operand in a
   catch arm mean "re-raise the matched error"? Alternatives: `_ -> rethrow`, or
   binding the residual (`rest -> raise rest`).
2. **`errdefer` scope and ordering.** Confirm `errdefer` fires LIFO with `defer`
   on escape paths and is skipped on normal completion, and whether a
   `successdefer` counterpart is worth adding (resolves the rest of DEC-011).
3. **Redundant-`try` severity.** Before the typechecker lands, is over-marking a
   warning or hard error? After it lands, hard error (§3.1 of design symmetry).
4. **Capability methods and operators.** `try` covers capability-method calls
   that declare `raises`. Operators/index that *panic* (e.g. out-of-bounds array
   read) are not `raise` and stay outside `try`; confirm the boundary.
5. **`stream { … }` and `yield`.** How `try` reads inside a `stream` body, and
   whether a stream's per-item `raises` row interacts with the consumer's `for`
   loop.
6. **Precedence of prefix `try`** relative to `?.`, `??`, and method-call `.` —
   pin the grammar so `(try a()).b` vs `try (a().b)` is unambiguous, ideally so
   the common "fallible leaf, then pure trailer" case needs no parens.
7. **Constraint on the future chaining form (design §2.11.3).** The deferred
   pipeline/method-chain syntax must preserve this RFC's invariant: every
   fallible link in a chain still carries its `try`, and propagation past a
   handler is still an explicit `raise`. A chaining form may remove intermediate
   *names*; it may not remove the visibility of which calls can fail. Whatever
   shape it takes has to be checkable against §2 rule 1 (try-required /
   try-forbidden) link by link.
8. **Scope-anchored error routing (future work).** A `raise … to 'Scope` form
   that routes an error past the nearest enclosing `catch` straight to a handler
   installed at a named scope, with the target recorded in the row:

   ```di
   raises {DbError to 'Transaction}      // typed + routed
   raises {E to 'Scope}                   // general shape
   ```

   The handler would attach to the scope's wiring (`with [...] @ 'Scope catch
   { … }`), making the scoped `catch` the discharge site for a scoped raise the
   way scoped `with` discharges a scoped `requires` — the error-path dual of
   scope-anchored capabilities (RFC-001 §4.2). It would collapse the
   level-by-level re-raise chaining of §5.4 for cases that are naturally
   scope-fatal (abort-at-`'Transaction`, request-fatal-at-`'Request`). Note it
   reduces *routing* ceremony, not per-frame declaration — the scoped row entry
   stays, for the same soundness reason `requires` entries do (a frame must
   record that it may exit to `'Scope` so the discharge site stays checkable). A
   coarser `raises {to 'Scope}` marker could trade type precision at the
   boundary for less enumeration. To be explored against real-world use cases
   before committing to a shape.
