// Scopes carve out finer-grained lifetimes than Process.
// A capability annotated `@ Request` can only be bound inside a `provide @ Request`,
// and the compiler rejects use of it from Process scope.

scope Request

capability RequestCtx @ Request {
    fn request_id() -> Uuid
    fn current_user() -> User?

    fn with_user(user: User) -> Self
}

capability Tenant @ Request {
    fn id() -> Uuid
    fn plan() -> Plan
}

// A handler runs inside a Request scope, so it can use RequestCtx + Tenant freely.
fn show_profile() -> Response
    requires {RequestCtx, Tenant, UserRepo}
    raises   {}
{
    let user = RequestCtx.current_user() ?? return Response.unauthorized()
    let plan = Tenant.plan()
    Response.ok({"user": user, "plan": plan})
}

// The connection handler establishes the Request scope by binding its caps.
// Anything inside the `in { ... }` block can see them; anything outside cannot.
fn handle_conn(sock: Socket, req: Request)
    requires {IO, UserRepo, TenantRepo, Logger}
{
    defer IO.close(sock)

    let tenant = lookup_tenant(req) ?? return write_response(sock, Response.bad_request("tenant"))

    provide @ Request {
        RequestCtx = RequestCtx.fresh(req)        @ Request
        Tenant     = tenant                       @ Request
    } in {
        let resp = show_profile()
        write_response(sock, resp)
    }
}
