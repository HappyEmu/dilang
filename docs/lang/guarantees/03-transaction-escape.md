# 03 — Transaction handle escaping its block

## Scenario

A money-transfer service performs two updates inside a transaction and writes an audit row afterwards. The transaction is scoped: BEGIN runs on entry to a `@ 'Transaction` block; COMMIT runs on normal exit; ROLLBACK runs on raised exit. The underlying connection is acquired from a pool when the block opens and returned to the pool when it closes (design §3.6.5).

Given:

```di
scope 'Transaction under 'Process

capability DbTx @ 'Transaction {
    fn execute(stmt: Sql)
    fn last_id() -> Int64
}

struct PgTransaction {
    conn: PgConn,
}
// PgTransaction implements DbTx, plus Lifecycle:
//   start():           conn.execute(sql"BEGIN")
//   shutdown(Normal):  conn.execute(sql"COMMIT");   pool.release(conn)
//   shutdown(Raised):  conn.execute(sql"ROLLBACK"); pool.release(conn)
```

## The bug

A developer wants to log the transfer to an audit table after the transaction succeeds. They reach for `DbTx` because it is the database thing they just used:

```di
fn transfer(from: UserId, to: UserId, amount: Money) -> Receipt
    requires {WriteDb}
    raises   {DbFailure}
{
    let receipt =
        with [ DbTx <- PgTransaction { conn: WriteDb.acquire() } ] @ 'Transaction {
            DbTx.execute(sql"UPDATE accounts SET balance = balance - ${amount} WHERE id = ${from}")
            DbTx.execute(sql"UPDATE accounts SET balance = balance + ${amount} WHERE id = ${to}")
            Receipt { id: DbTx.last_id() }
        }

    // ← out of the @ 'Transaction block; COMMIT has already run; conn is in the pool
    DbTx.execute(sql"INSERT INTO audit (event) VALUES ('transfer')")

    receipt
}
```

In Python, Node, Go, or any language with first-class connection objects the equivalent compiles. The `tx` variable is still in lexical scope; calling `tx.execute(...)` after the `with` block depends on the driver:

- **Best case**: the driver knows the transaction is closed and raises a runtime error. The audit row is missing; an oncall investigates next morning.
- **Worst case**: the connection has been returned to the pool and handed to another request. The `INSERT` lands on *that* connection, inside *that* transaction. The audit row is associated with an unrelated unit of work, and may be rolled back when the unrelated transaction rolls back. Audit log integrity is silently corrupted.

ORM-style "lazy" patterns make this worse: a query object returned from inside the transaction is evaluated on iteration later, against whatever connection state happens to be live.

## What dilang says

`DbTx` is declared `@ 'Transaction` (design §2.8.2). The trailing call to `DbTx.execute(...)` sits outside the `with` block. The compiler walks outward from that line looking for an enclosing `@ 'Transaction` scope. There is none — the surrounding scope is `@ 'Process` or whatever the caller of `transfer` had, which does not include `@ 'Transaction`. Per design §4.1.3:

```
error: capability `DbTx` is bound only inside `@ 'Transaction` scopes,
       but used here from outside any `@ 'Transaction` block
  --> transfer.di:14:5
   |
14 |     DbTx.execute(sql"INSERT INTO audit (event) VALUES ('transfer')")
   |     ^^^^ `DbTx.execute` requires {DbTx}, not available here
   |
note: the closest `@ 'Transaction` block ends here
  --> transfer.di:12:6
   |
 8 |     let receipt =
 9 |         with [ DbTx <- PgTransaction { conn: WriteDb.acquire() } ] @ 'Transaction {
   |         -------------------------------------------------------------------- block starts
10 |             ...
11 |             Receipt { id: DbTx.last_id() }
12 |         }
   |         - block ends; DbTx leaves scope
   |
note: `DbTx` is declared `@ 'Transaction` here
  --> caps.di:5:1
   |
 5 | capability DbTx @ 'Transaction { ... }
```

The error points at both the offending call and the block exit, so the relationship is obvious.

## The closure variant

The same check works through one level of indirection. A developer tries to defer the audit write via a background task:

```di
fn transfer(from: UserId, to: UserId, amount: Money) -> Receipt
    requires {WriteDb, TaskRunner}
    raises   {DbFailure}
{
    with [ DbTx <- PgTransaction { conn: WriteDb.acquire() } ] @ 'Transaction {
        DbTx.execute(sql"UPDATE accounts SET balance = balance - ${amount} WHERE id = ${from}")
        DbTx.execute(sql"UPDATE accounts SET balance = balance + ${amount} WHERE id = ${to}")

        TaskRunner.spawn(|| {
            DbTx.execute(sql"INSERT INTO audit (event) VALUES ('transfer')")
        })

        Receipt { id: DbTx.last_id() }
    }
}
```

Closures carry their inferred `requires` row as part of their function type (design §3.2, syntax §1.3). The closure passed to `TaskRunner.spawn` has inferred row `requires {DbTx}`. `TaskRunner.spawn`'s parameter type is `fn() -> Unit requires {} raises {}` — work scheduled to run *outside* the current scope can have no capability dependencies. Row unification fails:

```
error: closure has `requires {DbTx}` but expected `requires {}`
  --> transfer.di:11:24
   |
11 |         TaskRunner.spawn(|| {
   |         ----------------- expected: fn() -> Unit requires {} raises {}
12 |             DbTx.execute(sql"INSERT INTO audit (event) VALUES ('transfer')")
   |             ^^^^ closure uses DbTx, which is @ 'Transaction-scoped
13 |         })
```

Capturing `DbTx` into deferred work is rejected at compile time. The transaction handle cannot escape, directly or indirectly.

## The forced redesign

Two correct shapes drop out of the error. Either do the audit write inside the transaction (the usual answer — auditing the transaction *atomically* with its effects is what you actually want):

```di
fn transfer(from: UserId, to: UserId, amount: Money) -> Receipt
    requires {WriteDb}
    raises   {DbFailure}
{
    with [ DbTx <- PgTransaction { conn: WriteDb.acquire() } ] @ 'Transaction {
        DbTx.execute(sql"UPDATE accounts SET balance = balance - ${amount} WHERE id = ${from}")
        DbTx.execute(sql"UPDATE accounts SET balance = balance + ${amount} WHERE id = ${to}")
        DbTx.execute(sql"INSERT INTO audit (event) VALUES ('transfer')")
        Receipt { id: DbTx.last_id() }
    }
}
```

Or, if the audit really must run after the transfer commits (an external system call, for instance), capture the relevant *data* and use a separate, non-transactional capability:

```di
fn transfer(from: UserId, to: UserId, amount: Money) -> Receipt
    requires {WriteDb, AuditLog}
    raises   {DbFailure}
{
    let receipt =
        with [ DbTx <- PgTransaction { conn: WriteDb.acquire() } ] @ 'Transaction {
            DbTx.execute(sql"UPDATE accounts SET balance = balance - ${amount} WHERE id = ${from}")
            DbTx.execute(sql"UPDATE accounts SET balance = balance + ${amount} WHERE id = ${to}")
            Receipt { id: DbTx.last_id() }
        }

    AuditLog.record("transfer", {"from": from, "to": to, "amount": amount})

    receipt
}
```

`AuditLog` is a separate, process-scoped capability — its writes are not in the transaction. The trade-off is visible in the signature (`requires {WriteDb, AuditLog}`) and at the call site. The compiler made the developer choose explicitly, not silently inherit the wrong connection.

## What discipline alone can't catch

Three production failure modes collapse into the two compile errors above.

1. **Use-after-commit on a stale handle.** Code calls into the transaction object after the `with` / context-manager block has exited. Drivers vary: some raise, some silently succeed against the pooled connection. In dilang the call does not compile.

2. **Deferred work capturing the transaction.** Closures, spawned tasks, or queued callbacks that touch the transaction handle and execute after the block closes. Caught by row unification: the closure's `requires {DbTx}` cannot be passed where `requires {}` is expected.

3. **Lazy query objects iterated outside the block.** ORM patterns that return a queryset which fetches on iteration. The queryset's `.next()` method has `requires {DbTx}`; calling it after the block exits is a type error at the iteration site, not a runtime surprise.

`Lifecycle.shutdown` covers the runtime half of the guarantee: COMMIT or ROLLBACK *always* runs before the block returns, and the pool *always* gets a clean connection back. The compile-time check covers the other half: no code can be written that would reach for the handle once Lifecycle has cleaned up. The two halves together are what makes "scoped transactions" mean something stronger than "convention plus prayer."

## See also

- design §2.8 (Scopes are explicit), §3.6 (Scopes and Lifecycle)
- design §3.6.3 (Lifecycle start/shutdown ordering), §3.6.5 (transactions fit naturally)
- design §3.2 (Effect rows), syntax §1.3 (closure row inference)
- design §4.1.3 (Using a scoped capability outside its scope)
- DEC-004 (`@ 'ScopeName` mandatory on every binding)
- [Vignette 01](./01-job-vs-request-scope.md), [Vignette 02](./02-cross-tenant-leak.md) — the same scope 'mechanism under 'Process applied to different bug classes
