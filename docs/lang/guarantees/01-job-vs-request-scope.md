# 01 — Background jobs that reach for request state

## Scenario

A signup endpoint creates a user, then enqueues a background job to send a welcome email. The job runs later in a worker process. The handler and worker live in the same codebase, often the same file — and the worker often starts as copy-pasted lines from the request handler.

## The bug

A naive worker function reaches for the same request-scoped state the handler used:

```di
fn send_welcome_email(job: EmailJob)
    requires {Logger, Smtp, RequestCtx}      // ← look at this row
    raises   {SmtpFailed}
{
    let user   = RequestCtx.current_user() ?? panic("no user")
    let locale = user.preferred_locale
    let body   = render_welcome(locale, job.user_name)
    Smtp.send(job.to, "Welcome!", body)
}
```

In Python, Node, or Go the equivalent code compiles. It usually runs in dev because the worker happens to share a process with the request handler and `RequestCtx` is a thread-local that is either empty or — worse — contains a stale value from whichever request last touched the thread. Tests pass. In production the welcome email is silently personalised with the wrong user's locale, or the worker crashes on `None`.

## What dilang says

`RequestCtx` is declared `@ 'Request` (design §2.8.2). The worker loop opens a `@ 'Job` scope, not a `@ 'Request` one:

```di
fn run_worker()
    requires {JobQueue, Logger, Smtp}
    raises   {}
{
    loop {
        let job = JobQueue.next()
        with [ JobCtx <- JobCtx.fresh(job.id, job.attempt) ] @ 'Job {
            try send_welcome_email(job)
            catch SmtpFailed(e) -> Logger.error("email failed", {"err": e})
        }
    }
}
```

The compiler walks `send_welcome_email`'s `requires` row outward from the call site looking for a binding for `RequestCtx`. The enclosing scope is `@ 'Job`; there is no `@ 'Request` ancestor. Per design §4.1.3 (using a scoped capability outside its scope), this is rejected at compile time:

```
error: capability `RequestCtx` is bound only inside `@ 'Request` scopes,
       but `send_welcome_email` is called from a `@ 'Job` scope
  --> worker.di:14:17
   |
14 |             try send_welcome_email(job)
   |                 ^^^^^^^^^^^^^^^^^^ requires {RequestCtx}, not available here
   |
note: `RequestCtx` is declared `@ 'Request` here
  --> caps.di:3:1
   |
 3 | capability RequestCtx @ 'Request { ... }
```

The worker does not ship. The bug class — request-scoped state bleeding into background work — is gone before any test runs.

## The forced redesign

Anything the worker needs from the request must be captured as *data* in the job payload while the handler is still inside `@ 'Request`:

```di
struct EmailJob {
    to:        Str,
    user_name: Str,
    locale:    Locale,
}

fn send_welcome_email(job: EmailJob)
    requires {Logger, Smtp}                  // no RequestCtx
    raises   {SmtpFailed}
{
    let body = render_welcome(job.locale, job.user_name)
    Smtp.send(job.to, "Welcome!", body)
    Logger.info("sent welcome", {"to": job.to})
}

pub fn signup_handler(req: Request) -> Response
    requires {UserRepo, EmailJobQueue, RequestCtx}
    raises   {}
{
    let input  = req.json_body<SignupInput>().unwrap()
    let user   = UserRepo.create(input.email, input.name)
    let locale = RequestCtx.locale() ?? Locale.en   // read while still in @ 'Request
    EmailJobQueue.enqueue(EmailJob {
        to:        user.email,
        user_name: user.name,
        locale:    locale,
    })
    Response.ok()
}
```

The handler reads `RequestCtx.locale()` while it is still in `@ 'Request`, snapshots it into the `EmailJob` value, and enqueues. The worker is now self-contained: its `requires` row says exactly what it needs (`Logger`, `Smtp`), nothing more.

## What discipline alone can't catch

Three distinct failure modes collapse into one type error.

1. **Stale request context.** Worker reads `RequestCtx` and gets either `None` or the last request that ran on this thread. Impossible in dilang — `RequestCtx` cannot even be named outside `@ 'Request`.

2. **Logger context bleeding.** A request-scoped `Logger` re-binding that prefixes every line with `request_id=abc123` gets captured into a closure that runs hours later under a different request's id. The same scope 'rule under 'Process blocks it: the bleed shows up as a missing `@ 'Request` binding at compile time, not a wrong log line at 3am.

3. **Per-request connection-pool checkouts.** A `Db @ 'Request` binding that does `pool.checkout()` in `Lifecycle.start()` and `pool.release()` in `shutdown()` returns the connection to the pool when the request ends. If a worker tries to use the same `Db` cap later, it doesn't compile. If it could, it would be using a connection already handed to a different request.

None of these bugs requires a malicious or careless developer. They are the natural consequence of "I'll just reach for the thing I always reach for in a request handler." `@ 'Job` and `@ 'Request` being *different scopes* makes the reach a type error the first time someone tries it — typically when extracting worker code out of a request handler.

## See also

- design §2.8 (Scopes are explicit), §3.6 (Scopes and Lifecycle)
- design §4.1.3 (Using a scoped capability outside its scope)
- DEC-004 (`@ 'ScopeName` mandatory on every binding)
