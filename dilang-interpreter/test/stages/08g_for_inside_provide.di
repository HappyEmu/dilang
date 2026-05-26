capability Logger { fn info(msg: Str) }

fn main() {
    let xs = ["a", "b", "c"]
    provide { Logger = StdoutLogger @ Process } in {
        for x in xs {
            Logger.info("got ${x}")
        }
    }
}
