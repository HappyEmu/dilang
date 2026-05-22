capability Logger { fn info(msg: Str) }

fn greet(name: Str) requires {Logger} {
    Logger.info("hello, ${name}")
}

fn main() {
    provide { Logger = StdoutLogger @ Process } in {
        greet("world")
    }
}
