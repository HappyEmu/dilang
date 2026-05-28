capability Logger { fn info(msg: Str) }

fn main() {
    with [ Logger <- StdoutLogger ] {
        Logger.info("x")
    }
}
