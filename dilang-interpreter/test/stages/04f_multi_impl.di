capability Logger { fn info(msg: Str) }
capability Stamper { fn stamp(msg: Str) -> Str }

struct Combo {}

impl Logger for Combo {
    fn info(msg: Str) { print("log: ${msg}") }
}

impl Stamper for Combo {
    fn stamp(msg: Str) -> Str { "**${msg}**" }
}

fn main() {
    with [
        Stamper <- Combo @ 'Process
        Logger  <- Combo @ 'Process
    ] @ 'Process {
        Logger.info(Stamper.stamp("hi"))
    }
}
