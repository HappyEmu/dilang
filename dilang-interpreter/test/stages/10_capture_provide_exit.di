capability Logger { fn info(msg: Str) }

fn main() {
    // Build a closure that uses Logger *inside* a with block, store it,
    // then leave the with scope. Invoking it afterwards must still resolve
    // Logger from the captured capability stack.
    let f = with [ Logger <- StdoutLogger ] @ 'Process {
        || { Logger.info("captured logger still works") }
    }
    print("left the with block")
    f()
}
