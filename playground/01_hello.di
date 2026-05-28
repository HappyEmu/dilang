// The smallest program that exercises the capability model.
//
// `Logger` is a capability — the function declares it in `requires`,
// and `main` binds an implementation inside a `with` block.
// Nothing is global; the call to `Logger.info` resolves through the
// lexical `with` above it.

fn greet(name: Str)
    requires {Logger}
{
    Logger.info("hello, ${name}")
}

fn main() {
    with [Logger <- StdoutLogger] @ 'Process {
        greet("world")
    }
}
