capability Stamper { fn stamp(msg: Str) -> Str }
capability Greeter { fn say(msg: Str) }

struct ExclaimStamper {}
impl Stamper for ExclaimStamper {
    fn stamp(msg: Str) -> Str { "${msg}!" }
}

struct PrefixedGreeter {}
impl Greeter for PrefixedGreeter {
    requires {Stamper}
    fn say(msg: Str) { print(Stamper.stamp(msg)) }
}

fn main() {
    with [
        Stamper <- ExclaimStamper @ 'Process
        Greeter <- PrefixedGreeter @ 'Process
    ] @ 'Process { Greeter.say("hello") }
}
