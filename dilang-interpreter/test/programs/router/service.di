// Milestone 11.5 — route-table demo. The first program worth showing someone:
// a tiny HTTP router built from the value-method-dispatch mechanism (DEC-020)
// and short-circuit `&&` (DEC-021).
//
// `Route.handler` holds a function value (`fn(Request) -> Response`). It is a
// field, not an impl method, so it is invoked with the parenthesised call form
// `(r.handler)(req)` — `r.handler(req)` would be a method call (Rust rule).
//
// `Logger` is not in the prelude (only the HTTP caps are), so we declare it.
// `route` matches on method AND path-prefix with short-circuit `&&`.

capability Logger { fn info(msg: Str) }

struct Route { method: Str, prefix: Str, handler: fn(Request) -> Response }

fn route(req: Request, table: [Route]) -> Response {
    for r in table {
        if req.method == r.method && req.path.starts_with(r.prefix) {
            return (r.handler)(req)
        }
    }
    Response { status: 404, body: "no route" }
}

fn health(_: Request) -> Response { Response { status: 200, body: "ok" } }

fn echo(req: Request) -> Response { Response { status: 200, body: req.body } }

fn main() {
    with [
        Logger     <- StdoutLogger
        HttpServer <- BlockingHttpServer
    ] @ 'Process {
        let table = [
            Route { method: "GET",  prefix: "/health", handler: health },
            Route { method: "POST", prefix: "/echo",   handler: echo }
        ]
        HttpServer.serve(18080, |req| {
            Logger.info("${req.method} ${req.path}")
            route(req, table)
        })
    }
}
