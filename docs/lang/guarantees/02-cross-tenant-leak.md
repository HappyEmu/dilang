# 02 — Cross-tenant data leak in shared workers

## Scenario

A multi-tenant SaaS billing system. Two tenants — Acme and Initech — share a single Postgres database protected by row-level security: a session-level `app.tenant_id` setting determines which rows the database returns. A worker process pulls "send monthly invoice" jobs off a shared queue and emails the right invoice to the right customer. The worker pool is shared across tenants and reuses pooled database connections between jobs.

Given:

```di
scope 'Tenant under 'Process

capability TenantBilling @ 'Tenant {
    fn latest_unpaid() -> Invoice
    fn record_payment(invoice_id: InvoiceId, amount: Money)
}

struct PgBilling {
    tenant_id: TenantId,
}
// PgBilling implements TenantBilling, plus Lifecycle:
//   start():    WriteDb.execute(sql"SET LOCAL app.tenant_id = ${self.tenant_id}")
//   shutdown(): WriteDb.execute(sql"RESET app.tenant_id")
```

## The bug

A junior writes the worker by lifting code out of the request handler. They drop the request-scope 'wrappers under 'Process, since "this isn't a request":

```di
fn send_invoice(job: InvoiceJob)
    requires {Logger, Smtp, TenantBilling}
    raises   {SmtpFailed}
{
    let invoice = TenantBilling.latest_unpaid()           // ← which tenant?
    let pdf     = render_invoice(invoice)
    Smtp.send(invoice.customer_email, "Your invoice", pdf)
}

fn run_worker()
    requires {JobQueue, Logger, Smtp}
    raises   {}
{
    loop {
        let job = JobQueue.next()
        with [ JobCtx <- JobCtx.fresh(job.id, job.attempt) ] @ 'Job {
            try send_invoice(job)        // no @ 'Tenant anywhere
            catch SmtpFailed(e) -> Logger.error("invoice failed", {"err": e})
        }
    }
}
```

In Python, Node, or Go the equivalent code compiles. It often runs in dev with a single tenant. In production:

- **Best case**: RLS sees `app.tenant_id` unset, returns zero rows, the worker reports "nothing to invoice" and silently skips a billing cycle.
- **Worst case**: a pooled connection still has the *previous job's* `app.tenant_id` because the previous worker forgot to `RESET`. Acme's unpaid invoice gets emailed to an Initech customer. Compliance pages.

The bug is not exotic — it is the natural consequence of "lift the code, drop the wrapping middleware." Two-paragraph PR; weeks of incident postmortem.

## What dilang says

`TenantBilling` is declared `@ 'Tenant` (design §2.8.2). The worker's call to `send_invoice` happens inside a `@ 'Job` scope 'with under 'Process no enclosing `@ 'Tenant`. The compiler walks the requires row outward looking for a binding and finds none:

```
error: capability `TenantBilling` is bound only inside `@ 'Tenant` scopes,
       but `send_invoice` is called from a `@ 'Job` scope
  --> worker.di:11:17
   |
11 |             try send_invoice(job)
   |                 ^^^^^^^^^^^^ requires {TenantBilling}, not available here
   |
note: `TenantBilling` is declared `@ 'Tenant` here
  --> caps.di:5:1
   |
 5 | capability TenantBilling @ 'Tenant { ... }
```

A natural "fix" attempt is to bind `TenantBilling` directly in the existing `@ 'Job` block:

```di
with [
    JobCtx        = JobCtx.fresh(job.id, job.attempt),
    TenantBilling = PgBilling { tenant_id: job.tenant_id },   // wrong scope
] @ 'Job {
    try send_invoice(job)
    ...
}
```

This also fails to compile. Per design §4.1.3, a capability declared `@ 'Tenant` may be bound only in a `@ 'Tenant` block. Binding it in `@ 'Job` is rejected:

```
error: capability `TenantBilling` is declared `@ 'Tenant` but bound in a `@ 'Job` scope
  --> worker.di:9:13
   |
 9 |             TenantBilling = PgBilling { tenant_id: job.tenant_id },
   |             ^^^^^^^^^^^^^ binding lives in the wrong scope
```

The compiler will not let the developer paper over the missing scope.

## The forced redesign

The only way to satisfy both errors is to nest a `@ 'Tenant` scope 'inside under 'Process the `@ 'Job` scope, constructed from data carried by the job:

```di
fn run_worker()
    requires {JobQueue, Logger, Smtp}
    raises   {}
{
    loop {
        let job = JobQueue.next()
        with [ JobCtx <- JobCtx.fresh(job.id, job.attempt) ] @ 'Job {
            with [
                TenantBilling = PgBilling { tenant_id: job.tenant_id },
            ] @ 'Tenant {
                try send_invoice(job)
                catch SmtpFailed(e) -> Logger.error("invoice failed", {"err": e})
            }
        }
    }
}
```

Now Lifecycle does the runtime work that mirrors the compile-time check. On entry to the `@ 'Tenant` block, `PgBilling.start()` runs `SET LOCAL app.tenant_id = ...` on the connection. On exit — whether the body returns normally, raises `SmtpFailed`, or is cancelled — `PgBilling.shutdown(_)` runs `RESET app.tenant_id`. The connection is *always* clean when it returns to the pool.

Two compile-time guarantees fall out of this shape:

- A function that requires `TenantBilling` cannot be called from `@ 'Process` startup, from `@ 'Job` housekeeping code, or from any place that has not constructed a tenant binding. Cross-tenant calls are not "rare and audited" — they are *unrepresentable*.
- The `tenant_id` in the binding has to come from somewhere. The compiler does not know whether `job.tenant_id` is the right one, but it forces the developer to *answer the question* "which tenant?" at the exact site where the binding is constructed. In the buggy code, no one ever asked.

## What discipline alone can't catch

Three failure modes that production multi-tenant systems repeatedly suffer collapse into the two compile errors above.

1. **Forgotten tenant scope.** Worker reaches for `TenantBilling.latest_unpaid()` with no tenant ever established. RLS returns zero rows, the job silently no-ops, billing cycles disappear. In dilang the call does not compile.

2. **Connection state bleed between jobs.** A pooled connection still has the previous job's `app.tenant_id`. Worker reads or writes against the wrong tenant. `Lifecycle.shutdown()` runs on every `@ 'Tenant` block exit, including the raised and cancelled paths (design §3.6.3, §3.6.4) — `RESET` is guaranteed before the connection returns to the pool.

3. **Hardcoded tenant in a long-lived binding.** A `@ 'Process`-level binding of `TenantBilling` pinned to a single tenant_id at boot, accidentally reused across all jobs. Cannot happen: `TenantBilling` is `@ 'Tenant`-declared and cannot be bound in `@ 'Process` at all.

## Limits of the guarantee

The compiler enforces that a `@ 'Tenant` scope 'exists under 'Process around any `TenantBilling` call, and that the scope's Lifecycle hooks fire on entry and exit. It does **not** enforce that the `tenant_id` passed to `PgBilling` is the *right* one for the job — that is runtime data, and the compiler treats `job.tenant_id` as opaque.

What the compiler does do is force the question to be asked at the binding site, on the call path between job dequeue and capability use, in code the reviewer can read linearly. A `tenant_id` mismatch becomes a localised, reviewable bug rather than an ambient, sometimes-it-happens one. Combined with database-level RLS, the two layers fail closed: even if a developer wires the wrong `tenant_id`, the RLS policy on `app.tenant_id` is what the database actually checks.

## See also

- design §2.8 (Scopes are explicit), §3.6 (Scopes and Lifecycle)
- design §3.6.3 (Lifecycle start/shutdown ordering), §3.6.4 (shutdown on raised exit)
- design §4.1.3 (Using a scoped capability outside its scope)
- DEC-004 (`@ 'ScopeName` mandatory on every binding)
- [Vignette 01](./01-job-vs-request-scope.md) — the same scope 'mechanism under 'Process applied to request-scoped state
