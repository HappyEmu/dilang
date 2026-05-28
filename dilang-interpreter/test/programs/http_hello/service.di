capability Logger { fn info(msg: Str) }

fn main() {
    provide {
        Logger = StdoutLogger @ Process,
        HttpServer = BlockingHttpServer @ Process
    } in {
        HttpServer.serve(18080, |req| {
            Logger.info("handling ${req.path}")
            Response { status: 200, body: "ok" }
        })
    }
}
