capability Logger {
    fn info(msg: Str)
}

fn say(s: Str) {
    Logger.info(s)
}

// Two `with` frames, one nested inside the other. The inner frame
// re-binds Logger; the inner call should hit the inner impl, the outer
// calls (after the inner block exits) should fall back to the outer one.
fn main() {
    with [ Logger <- StdoutLogger @ 'Process ] @ 'Process {
        say("outer-1")
        with [ Logger <- StdoutLogger @ 'Process ] @ 'Process {
            say("inner")
        }
        say("outer-2")
    }
}
