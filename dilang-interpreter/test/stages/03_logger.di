capability Logger { fn info(msg: Str) }

fn greet(name: Str) requires {Logger} {
    Logger.info("hello, ${name}")
}

fn main() {
    with [ Logger <- StdoutLogger @ 'Process ] @ 'Process {
        greet("world")
    }
}
