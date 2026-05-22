capability Logger { fn info(msg: Str) }

struct PrefixedLogger { prefix: Str }
impl Logger for PrefixedLogger {
    fn info(msg: Str) { print("${self.prefix}: ${msg}") }
}

fn main() {
    provide { Logger = PrefixedLogger { prefix: "app" } @ Process } in {
        Logger.info("hello")
        Logger.info("world")
    }
}
