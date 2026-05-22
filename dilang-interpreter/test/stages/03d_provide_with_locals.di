capability Logger {
    fn info(msg: Str)
}

fn shout(prefix: Str, msg: Str) requires {Logger} {
    let combined = "${prefix}: ${msg}"
    Logger.info(combined)
}

fn main() {
    let header = "boot"
    provide { Logger = StdoutLogger() @ Process } in {
        let count = 3
        shout(header, "starting (count=${count})")
        shout(header, "computed = ${1 + 2 * 3}")
        Logger.info("plain line, length ~ ${count * 10}")
    }
    // Outside the provide block, locals from outside are still available.
    print(header)
}
