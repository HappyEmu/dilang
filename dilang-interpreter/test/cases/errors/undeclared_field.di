capability Logger { fn info(msg: Str) }

struct PrefixedLogger { prefix: Str }
impl Logger for PrefixedLogger {
    fn info(msg: Str) { print(self.nope) }
}

fn main() {
    with [ Logger <- PrefixedLogger { prefix: "x" } @ 'Process ] @ 'Process {
        Logger.info("y")
    }
}
