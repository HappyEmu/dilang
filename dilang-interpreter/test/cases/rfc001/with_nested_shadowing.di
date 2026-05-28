capability Logger { fn info(msg: Str) }

struct Outer {}
impl Logger for Outer {
    fn info(msg: Str) { print("outer:${msg}") }
}

struct Inner {}
impl Logger for Inner {
    fn info(msg: Str) { print("inner:${msg}") }
}

fn main() {
    with [ Logger <- Outer ] @ 'Process {
        Logger.info("x")
        with [ Logger <- Inner ] @ 'Process {
            Logger.info("x")
        }
        Logger.info("x")
    }
}
