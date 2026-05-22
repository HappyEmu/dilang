// The struct literal's field value is computed by a user fn call.
capability Logger { fn info(msg: Str) }

struct PrefixedLogger { prefix: Str }
impl Logger for PrefixedLogger {
    fn info(msg: Str) { print("${self.prefix}: ${msg}") }
}

fn build_prefix(name: Str) -> Str {
    "svc-${name}"
}

fn main() {
    provide {
        Logger = PrefixedLogger { prefix: build_prefix("auth") } @ Process
    } in {
        Logger.info("ready")
        Logger.info("ok")
    }
}
