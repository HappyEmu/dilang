capability Logger { fn info(msg: Str) }

struct PrefixedLogger { prefix: Str }
impl Logger for PrefixedLogger {
    fn info(msg: Str) { print(self.prefix) }
}

fn main() {
    with [ Logger <- PrefixedLogger { prefix: "x", bogus: "y" } @ 'Process ] @ 'Process {
        Logger.info("x")
    }
}
