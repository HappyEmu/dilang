// Middleware is just a function that wraps a handler.
// Row polymorphism lets one middleware wrap any handler regardless of what
// capabilities that handler needs — the row variable `R` carries them through.

// Logs the request and timing around any handler.
fn with_request_logging<R, E>(
    handler: fn() -> Response requires {R} raises {E}
) -> Response
    requires {R, Logger, Clock, RequestCtx}
    raises   {E}
{
    let start = Clock.now()
    let id    = RequestCtx.request_id()
    Logger.info("→ request", {"id": id})
    let res = handler()
    Logger.info("← request", {
        "id":     id,
        "status": res.status,
        "ms":     (Clock.now() - start).as_millis(),
    })
    res
}

// Auth middleware adds `RequestCtx` to the handler's row by re-binding it
// in a Request-scoped `provide`. The handler sees `current_user()` reflect
// the user this middleware verified.
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

    provide @ Request {
        RequestCtx = RequestCtx.with_user(user) @ Request
    } in {
        handler()
    }
}

// Composition is plain function calls — no decorator syntax, no implicit chain.
fn dispatch(req: Request, router: Router<{TaskRepo, RequestCtx}>) -> Response
    requires {Logger, Clock, RequestCtx, UserRepo, TokenSigner, TaskRepo}
{
    with_request_logging(||
        with_auth(req, ||
            router.dispatch(req).unwrap_or(Response.not_found())))
}
