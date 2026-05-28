capability Greeter { fn say(msg: Str) }

struct AdornedGreeter { prefix: Str, suffix: Str, mark: Str }
impl Greeter for AdornedGreeter {
    fn say(msg: Str) {
        print("${self.prefix}${msg}${self.suffix}${self.mark}")
    }
}

fn main() {
    with [
        Greeter <- AdornedGreeter { prefix: "[", suffix: "]", mark: "!" } @ 'Process
    ] @ 'Process {
        Greeter.say("hi")
        Greeter.say("bye")
    }
}
