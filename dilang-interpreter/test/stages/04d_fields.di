capability Logger { fn info(msg: Str) }

struct PrefixedLogger { prefix: Str }
impl Logger for PrefixedLogger {
    fn info(msg: Str) { print("${self.prefix}: ${msg}") }
}

fn main() {
    with [ Logger <- PrefixedLogger { prefix: "app" } @ 'Process ] @ 'Process {
        Logger.info("hello")
        Logger.info("world")
    }
}
