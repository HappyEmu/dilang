# RFC-001 — `with` scoped wiring syntax

Status: Accepted for the next surface-syntax pass; not implemented by the
current interpreter.

The interpreter currently implements the Stage 3/4 `provide` syntax:

```di
provide {
    RequestCtx = fresh_ctx(req) @ Request
} in {
    handler()
}
```

This RFC locks in the replacement syntax for capability provisioning, scoped
lifetime entry, and Wiring composition:

```di
with [
    RequestCtx <- fresh_ctx(req)
] @ 'Request {
    handler()
}
```

The semantic model is unchanged: capabilities are still lexically scoped,
bindings are still evaluated in order, later entries still shadow earlier
entries, and a body evaluates with the bound capabilities in scope. The change
is purely surface syntax, plus a more explicit lifetime-scope notation.

-----

## 1. Summary of changes

### 1.1 Scope names are lifetime identifiers

Current docs and interpreter plans:

```di
scope Request
scope Transaction
capability RequestCtx @ Request { fn user_id() -> Uuid }
```

New syntax:

```di
scope 'Request under 'Process
scope 'Transaction under 'Request

capability RequestCtx @ 'Request { fn user_id() -> Uuid }
```

The leading apostrophe gives the lexer a distinct token class for lifetime
scopes and makes scope names visually different from types, capabilities, and
modules.

`under` expresses lifetime nesting:

```text
'Transaction is under 'Request, which is under 'Process.
Inner scopes may access capabilities from ancestor scopes.
Ancestor scopes may not depend on capabilities from descendants.
```

Use `under` for lifetime nesting. Keep `extends` for interface
substitutability:

```di
scope 'Transaction under 'Request
capability WriteDb extends ReadDb
trait Ord extends Eq
```

### 1.2 `with [...] @ 'Scope { ... }` replaces scoped `provide`

Current docs/plans:

```di
provide @ Request {
    RequestCtx = fresh_ctx(req) @ Request
} in {
    handler()
}
```

New syntax:

```di
with [
    RequestCtx <- fresh_ctx(req)
] @ 'Request {
    handler()
}
```

The scope annotation after the binding list applies to every entry that does
not carry its own explicit `@ 'Scope`.

### 1.3 Binding entries use `<-`

Current interpreter/docs:

```di
Logger = JsonLogger @ Process
```

New syntax:

```di
Logger <- JsonLogger
```

Inside a scoped `with [...] @ 'Scope`, the binding inherits the block scope.
Inside a mixed-scope `with [...]`, each binding must state its scope:

```di
with [
    Logger      <- JsonLogger       @ 'Process
    CurrentUser <- session_user(req) @ 'Request
] {
    handler()
}
```

`<-` is a provisioning binder, not lazy evaluation. The RHS is evaluated once
when entering the scope instance, in lexical order, and the resulting impl is
bound for the body. If the impl has `Lifecycle`, startup and shutdown attach to
that scope entry as before.

### 1.4 Spread replaces `using`

Current interpreter plan:

```di
provide {
    using runtime(), repos(),
    Logger = TestLogger @ Process,
} in {
    run_test()
}
```

New syntax:

```di
with [
    ...runtime()
    ...repos()
    Logger <- TestLogger @ 'Process
] {
    run_test()
}
```

`...wiring_expr` splices a `Wiring` into the binding list at that lexical
position. Later entries override earlier entries for the same capability at
the same scope.

### 1.5 `with [...]` is an expression and can produce `Wiring`

With a body:

```di
fn main() = with [
    ...prod_wiring()
] {
    serve(8080, router())
}
```

Without a body:

```di
fn prod_wiring() -> Wiring = with [
    Logger      <- JsonLogger    @ 'Process
    LicenseRepo <- PgLicenseRepo @ 'Process
    HttpClient  <- EioHttpClient @ 'Process
]
```

The expression form removes the extra function-body nesting that `provide ...
in { ... }` encouraged.

-----

## 2. Syntax reference

```di
scope 'Child under 'Parent

capability CapName [@ 'Scope] {
    fn method(...)
}

with [
    Cap <- expr
    ...wiring_expr
] @ 'Scope {
    body
}

with [
    CapA <- exprA @ 'ScopeA
    CapB <- exprB @ 'ScopeB
    ...wiring_expr
] {
    body
}

with [
    Cap <- expr @ 'Scope
    ...wiring_expr
]
```

Rules:

1. `with [entries] @ 'Scope { body }` enters a fresh instance of `'Scope`.
   Bindings without an explicit `@` are bound at `'Scope`.
2. `with [entries] { body }` is mixed-scope. Every direct binding must carry
   `@ 'Scope`; spread Wirings keep their own recorded scopes.
3. `with [entries] @ 'Scope` without a body produces a `Wiring` whose direct
   bindings default to `'Scope`.
4. `with [entries]` without a body produces a mixed-scope `Wiring`; every
   direct binding must carry `@ 'Scope`.
5. Entries evaluate left-to-right. A binding RHS can see capabilities bound by
   earlier entries and by ancestor scopes. Forward references are compile
   errors.
6. Later entries shadow earlier entries for the same capability at the same
   scope.
7. A binding at scope `'S` may depend only on capabilities from `'S` or
   ancestors of `'S`.
8. A value or closure whose row mentions a shorter-lived scope cannot escape
   to an ancestor scope.

-----

## 3. Why this shape

### 3.1 `with`, not `provide`

`provide ... in ...` is precise but heavy. It reads like compiler terminology,
not application code. The new form reads as a scoped region:

```di
with [
    RequestCtx <- fresh_ctx(req)
] @ 'Request {
    handler()
}
```

That is the common phrase programmers already use: run this code with these
bindings.

### 3.2 Scope after the binding list

Rejected:

```di
with @ 'Request [
    RequestCtx <- fresh_ctx(req)
] {
    handler()
}
```

`with @ 'Request` is sigil-heavy and reads awkwardly. Placing `@ 'Scope` after
the list makes it modify the bindings:

```di
with [bindings] @ 'Scope { body }
```

Read it as: "with these bindings at this scope, evaluate this body."

### 3.3 Square brackets, not parens

The binding group is a distinct provisioning list, not ordinary function
arguments. Square brackets also avoid confusing `with (...)` with a call-like
construct.

### 3.4 `<-`, not `=` or `=>`

`=` looks like ordinary value assignment. `=>` strongly suggests a function or
lazy thunk. `<-` says "bind this capability from this provider expression"
without changing evaluation semantics.

### 3.5 `...`, not `using`

Once entries live inside a binding list, spread is the most direct notation for
Wiring composition:

```di
with [
    ...base_runtime()
    Logger <- TestLogger @ 'Process
] {
    run_test()
}
```

It makes override order visible without adding another directive keyword.

-----

## 4. Migration examples

### 4.1 Process wiring

Current docs/plans:

```di
fn prod_runtime() -> Wiring {
    provide {
        Logger      = JsonLogger    @ Process
        LicenseRepo = PgLicenseRepo @ Process
        HttpClient  = EioHttpClient @ Process
    }
}

fn main() {
    provide {
        using prod_runtime()
    } in {
        serve(8080, router())
    }
}
```

New syntax:

```di
fn prod_runtime() -> Wiring = with [
    Logger      <- JsonLogger    @ 'Process
    LicenseRepo <- PgLicenseRepo @ 'Process
    HttpClient  <- EioHttpClient @ 'Process
]

fn main() = with [
    ...prod_runtime()
] {
    serve(8080, router())
}
```

### 4.2 Request scope

Current docs/plans:

```di
scope Request

capability CurrentUser @ Request {
    fn id() -> UserId
}

fn handle(req: Request) -> Response {
    provide @ Request {
        CurrentUser = session_user(req) @ Request
    } in {
        router(req)
    }
}
```

New syntax:

```di
scope 'Request under 'Process

capability CurrentUser @ 'Request {
    fn id() -> UserId
}

fn handle(req: Request) -> Response = with [
    CurrentUser <- session_user(req)
] @ 'Request {
    router(req)
}
```

### 4.3 Transaction scope

```di
scope 'Request under 'Process
scope 'Transaction under 'Request

capability DbTx @ 'Transaction {
    fn execute(sql: Sql) raises {DbError}
    fn last_id() -> I64
}

fn transfer(req: TransferRequest) -> Receipt
    requires {WriteDb}
    raises   {DbFailure}
= with [
    DbTx <- PgTransaction { conn: WriteDb.acquire() }
] @ 'Transaction {
    try {
        DbTx.execute(sql"UPDATE accounts SET balance = balance - ${req.amount}")
        DbTx.execute(sql"UPDATE accounts SET balance = balance + ${req.amount}")
        Receipt { id: DbTx.last_id() }
    } catch DbError(e) -> raise DbFailure(e)
}
```

`DbTx` cannot be used after the `with` expression exits, and closures requiring
`DbTx` cannot be passed to a longer-lived scheduler unless their function type
allows the `'Transaction` requirement.

-----

## 5. Showcase examples

### 5.1 Licensed external service per logged-in user

This example shows the main reason the mechanism exists: a business capability
can hide implementation-private dependencies, while still forcing the caller to
establish the right short-lived authority.

```di
scope 'Request under 'Process
scope 'ExternalSession under 'Request

capability CurrentUser @ 'Request {
    fn id() -> UserId
}

capability LicenseRepo @ 'Process {
    fn license_for(user: UserId, service: Str) -> License? raises {DbError}
}

capability HttpClient @ 'Process {
    fn post(url: Str, headers: Map<Str, Str>, json: Json) raises {HttpError}
}

capability Crm @ 'ExternalSession {
    fn push_contact(c: Contact) raises {CrmError}
}

struct LicensedCrm {
    service: Str
}

impl Crm for LicensedCrm {
    requires {CurrentUser, LicenseRepo, HttpClient}

    fn push_contact(c: Contact) raises {CrmError} {
        let user_id = CurrentUser.id()

        let license = try LicenseRepo.license_for(user_id, self.service)
            catch DbError(e) -> raise CrmError.LicenseLookupFailed(e)

        let license = license ?? raise CrmError.NotLicensed

        try HttpClient.post(
            "https://crm.example.com/contacts",
            headers: { "Authorization": "Bearer ${license.token}" },
            json: Contact.to_json(c),
        ) catch HttpError(e) -> raise CrmError.RemoteFailed(e)
    }
}

fn create_contact(req: Request) -> Response = with [
    CurrentUser <- session_user(req)
] @ 'Request {
    with [
        Crm <- LicensedCrm { service: "crm" }
    ] @ 'ExternalSession {
        let contact = parse_contact(req)
        Crm.push_contact(contact)
        Response.ok()
    }
}
```

`create_contact` depends on `Crm`, not on `LicenseRepo` or `HttpClient`. The
license lookup is private to the `LicensedCrm` implementation. The compiler
still checks that `CurrentUser`, `LicenseRepo`, and `HttpClient` are available
where `Crm` is bound.

The rejected shape is exactly the production bug this mechanism prevents:

```di
fn nightly_sync()
    requires {Crm}
{
    Crm.push_contact(...)
}
```

A process-level job cannot just "inject the CRM client". It must establish an
account or user authority first, so the reviewer can see which license
authorizes the external call.

### 5.2 Background job reconstructs authority from data

```di
scope 'Job under 'Process
scope 'Account under 'Job
scope 'ExternalSession under 'Account

capability AccountCtx @ 'Account {
    fn user_id() -> UserId
}

impl Crm for LicensedCrm {
    requires {AccountCtx, LicenseRepo, HttpClient}

    fn push_contact(c: Contact) raises {CrmError} {
        let license = LicenseRepo.license_for(AccountCtx.user_id(), self.service)
            ?? raise CrmError.NotLicensed
        HttpClient.post(self.endpoint, auth(license), Contact.to_json(c))
    }
}

fn sync_contact_job(job: SyncContactJob) = with [
    JobCtx <- job_context(job.id)
] @ 'Job {
    with [
        AccountCtx <- account_from_job(job.user_id)
    ] @ 'Account {
        with [
            Crm <- LicensedCrm { service: "crm" }
        ] @ 'ExternalSession {
            Crm.push_contact(job.contact)
        }
    }
}
```

The job receives data (`job.user_id`), reconstructs the account authority, and
then opens the external-service session. It cannot accidentally reuse a
request-scoped `CurrentUser` because `'Request` is not in its ancestor chain.

### 5.3 Request logger override without ambient context

```di
scope 'Request under 'Process

capability Logger {
    fn info(msg: Str, fields: Map<Str, Json> = {})
}

capability RequestCtx @ 'Request {
    fn request_id() -> Uuid
}

fn main() = with [
    Logger <- JsonLogger @ 'Process
] {
    serve(8080, router())
}

fn handle(req: Request) -> Response = with [
    RequestCtx <- fresh_request_ctx(req)
    Logger     <- RequestLogger {
        base: Logger,
        request_id: req.id,
    }
] @ 'Request {
    Logger.info("request started")
    router(req)
}
```

Inside the request, `Logger` carries request metadata. Outside the request, it
is the process logger. No thread-local logging context has to be cleared when
the request ends.

### 5.4 Test wiring with targeted overrides

```di
fn prod_wiring() -> Wiring = with [
    Logger      <- JsonLogger    @ 'Process
    Clock       <- SystemClock   @ 'Process
    LicenseRepo <- PgLicenseRepo @ 'Process
    HttpClient  <- EioHttpClient @ 'Process
]

fn test_wiring() -> Wiring = with [
    ...prod_wiring()
    Logger      <- TestLogger      @ 'Process
    Clock       <- FixedClock.now  @ 'Process
    LicenseRepo <- InMemoryLicenses @ 'Process
]

test "licensed CRM posts with user license" = with [
    ...test_wiring()
] {
    let req = fake_request(user: "u1")
    let res = create_contact(req)
    assert res.status == 200
}
```

The test graph is a lexical composition of Wirings. The override order is local
and visible: entries after `...prod_wiring()` replace production bindings.

-----

## 6. Parser and interpreter impact

The current interpreter does not implement this RFC. The migration is mostly
surface syntax but is not zero-cost:

1. Lexer: add lifetime tokens for apostrophe-prefixed names, `<-`, and `...`.
2. Parser: replace or parallel the existing `Provide` grammar with `with`
   expressions and square-bracket entry lists.
3. AST: either rename `Provide` to a neutral node (`WithCaps`, `CapScope`) or
   keep `Provide` as the semantic node and map `with` into it.
4. Scope model: update scope identifiers from plain `ident` to lifetime names.
5. Wiring entries: replace `Using` with spread entries.
6. Tests: keep old interpreter stage tests until the syntax migration stage,
   then mechanically rewrite `provide` examples to `with`.

The semantic core should not change: capability lookup, left-to-right binding,
shadowing, impl-private `requires`, `Lifecycle`, and Wiring static checks all
stay the same.

-----

## 7. Open questions

1. Whether capability scope annotations should be mandatory or optional.
   Current leaning: optional restriction on capability declarations, explicit
   or inherited location on bindings.
2. Whether mixed-scope `with [ ... ] { ... }` should auto-enter all listed
   scopes or require explicit nesting when the scopes are not on one ancestor
   path.
3. Whether `with [entries] @ 'Scope` without a body should produce a
   single-scope Wiring or be rejected in favor of explicit `@` on each entry.
4. Whether old `provide` should remain as a compatibility alias for one
   migration stage or be removed in one syntax-breaking release.
