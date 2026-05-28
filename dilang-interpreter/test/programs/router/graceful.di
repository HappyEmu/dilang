// A runnable approximation of v4 design §4.8 ("HTTP server with graceful
// shutdown"), trimmed to what the interpreter supports today.
//
// What IS here (all on current primitives):
//   - `Router` as a STRUCT with builder methods `.get` / `.post` and `.dispatch`,
//     called via value-method dispatch (DEC-020). `.get`/`.post` mutate the
//     route list and return `self`, so calls chain like v4's `Router.new().get(..)`.
//   - Short-circuit `&&` (DEC-021) in the route match.
//   - `defer` for deterministic cleanup: per-request (the handler closure's
//     block) and at shutdown (the `provide ... in` block).
//   - "Graceful shutdown" = the bounded accept loop (`--max-requests`) returns,
//     the `provide` block exits, and its `defer` fires the shutdown log.
//
// What §4.8 needs that does NOT exist yet (see the handoff gap table):
//   - `provide @ Request { RequestCtx = ... }`  -> Stage 12 (scopes)
//   - `io.Tasks.async` / `Group` / `.concurrent` -> Stage 15 (concurrency)
//   - `with_timeout(30.seconds)` / `Cancelled`   -> Stage 16 (cancellation)
//   - signal-driven drain, `Net`-authority bind/accept/close, maps, associated
//     fns (`Response.ok(...)`), `Clock`, `sql""`, generics-with-rows.
// So this is graceful-in-spirit (clean, deterministic teardown) but not
// signal-driven or concurrent.

capability Logger { fn info(msg: Str) }

struct Route  { method: Str, prefix: Str, handler: fn(Request) -> Response }
struct Router { routes: [Route] }

// Inherent impl (DEC-022): a `Router` is value-shaped, so its methods are its
// own — no capability/trait interface. They reach the value through value-method
// dispatch (DEC-020), never through `provide`.
impl Router {
    fn get(prefix: Str, handler: fn(Request) -> Response) -> Router {
        self.routes.push(Route { method: "GET", prefix: prefix, handler: handler })
        self
    }
    
    fn post(prefix: Str, handler: fn(Request) -> Response) -> Router {
        self.routes.push(Route { method: "POST", prefix: prefix, handler: handler })
        self
    }
    
    fn dispatch(req: Request) -> Response {
        for r in self.routes {
            if req.method == r.method && req.path.starts_with(r.prefix) {
                return (r.handler)(req)
            }
        }
        
        Response { status: 404, body: "no route\n" }
    }
}

fn new_router() -> Router { Router { routes: [] } }

fn hello(_: Request) -> Response { Response { status: 200, body: "Hello, world!\n" } }
fn echo(req: Request) -> Response { Response { status: 200, body: req.body } }

fn main() {
    provide {
        Logger     = StdoutLogger         @ Process
        HttpServer = BlockingHttpServer   @ Process
    } in {
        defer Logger.info("server shut down")

        let router = new_router()
            .get("/",     hello)
            .post("/echo", echo)

        Logger.info("listening on 18080")
        
        HttpServer.serve(18080, |req| {
            defer Logger.info("closed ${req.method} ${req.path}")

            Logger.info("handling ${req.method} ${req.path}")

            router.dispatch(req)
        })
    }
}
