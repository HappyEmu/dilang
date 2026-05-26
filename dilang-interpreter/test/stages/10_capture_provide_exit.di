capability Logger { fn info(msg: Str) }

fn main() {
    // Build a closure that uses Logger *inside* a provide block, store it,
    // then leave the provide scope. Invoking it afterwards must still resolve
    // Logger from the captured capability stack.
    let f = provide { Logger = StdoutLogger @ Process } in {
        || { Logger.info("captured logger still works") }
    }
    print("left the provide block")
    f()
}
