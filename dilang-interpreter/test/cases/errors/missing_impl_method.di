capability Logger { fn info(msg: Str) }

struct Empty {}
impl Logger for Empty {}

fn main() {
    with [ Logger <- Empty @ 'Process ] @ 'Process {
        Logger.info("x")
    }
}
