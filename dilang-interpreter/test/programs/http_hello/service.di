capability Logger { fn info(msg: Str) }

fn main() {
    with [
        Logger <- StdoutLogger,
        HttpServer <- BlockingHttpServer
    ] @ 'Process {
        HttpServer.serve(18080, |req| {
            Logger.info("handling ${req.path}")
            Response { status: 200, body: "ok" }
        })
    }
}
