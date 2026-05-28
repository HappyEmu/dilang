capability Logger { fn info(msg: Str) }

struct PrefixedLogger { prefix: Str }
impl Logger for PrefixedLogger {
    fn info(msg: Str) { print(self.prefix) }
}

fn main() {
    with [ Logger <- PrefixedLogger {} @ 'Process ] @ 'Process {
        Logger.info("x")
    }
}
