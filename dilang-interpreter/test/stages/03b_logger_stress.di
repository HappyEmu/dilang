capability Logger {
    fn info(msg: Str)
    fn warn(msg: Str)
}

capability Greeter {
    fn hello(name: Str)
}

// Caller does NOT list Logger in `requires`; proves lookup is by
// lexical cap-stack at the call site, not by the declared rows.
fn deep(name: Str) {
    Logger.info("deep saw: ${name}")
    Logger.warn("deep is warning about ${name}")
}

fn middle(name: Str) requires {Greeter} {
    Greeter.hello(name)
    deep(name)
}

fn outer(name: Str) requires {Logger, Greeter} {
    Logger.info("outer start with ${name}")
    middle(name)
    Logger.info("outer end with ${name}")
}

fn main() {
    with [
        Logger  <- StdoutLogger  @ 'Process,
        Greeter <- StdoutGreeter @ 'Process
    ] @ 'Process {
        outer("alice")
        outer("bob")
    }
}
