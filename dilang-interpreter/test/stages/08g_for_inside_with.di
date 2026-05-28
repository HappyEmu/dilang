capability Logger { fn info(msg: Str) }

fn main() {
    let xs = ["a", "b", "c"]
    with [ Logger <- StdoutLogger @ 'Process ] @ 'Process {
        for x in xs {
            Logger.info("got ${x}")
        }
    }
}
