capability Logger { fn info(msg: Str) }

fn main() {
    with [ Logger <- StdoutLogger @ 'Process ] @ 'Process {
        Logger.bogus("x")
    }
}
