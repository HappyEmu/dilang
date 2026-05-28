// Capability-swap proof (interpreter.md:1091). The HTTP handler below is
// byte-for-byte identical to the one in service.di; the ONLY change is the
// `Logger` binding at `main` — a user `PrefixedLogger` struct instead of the
// host `StdoutLogger`. If the handler's log line gains the prefix with no other
// edit, the handler closure's *captured* capability stack crossed the OCaml
// host call boundary in `BlockingHttpServer.serve`.

capability Logger { fn info(msg: Str) }

struct PrefixedLogger { prefix: Str }
impl Logger for PrefixedLogger {
    fn info(msg: Str) { print("${self.prefix}${msg}") }
}

fn main() {
    with [
        Logger <- PrefixedLogger { prefix: "[svc] " },
        HttpServer <- BlockingHttpServer
    ] @ 'Process {
        HttpServer.serve(18080, |req| {
            Logger.info("handling ${req.path}")
            Response { status: 200, body: "ok" }
        })
    }
}
