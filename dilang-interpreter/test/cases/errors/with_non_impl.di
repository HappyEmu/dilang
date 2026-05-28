capability Logger { fn info(msg: Str) }

fn main() {
    with [ Logger <- 42 @ 'Process ] @ 'Process {
        Logger.info("x")
    }
}
