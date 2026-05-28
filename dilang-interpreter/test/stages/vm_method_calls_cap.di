// DEC-020: a struct value's user method runs with the CALLER's caps
// (`ctx.caps`), not the impl's captured `cap_env`. `b` is built OUTSIDE the
// `provide` (so its own cap_env is empty), but `b.announce()` is called INSIDE
// it, so `Logger.info` resolves against the provide stack active at the call
// site. If value dispatch wrongly used the impl's empty cap_env, this would
// fail with "Logger not in scope".

capability Logger { fn info(msg: Str) }
capability Tagged { fn announce() }

struct Banner { label: Str }

impl Tagged for Banner {
    fn announce() { Logger.info("banner: ${self.label}") }
}

fn main() {
    let b = Banner { label: "hi" }
    provide { Logger = StdoutLogger @ Process } in {
        b.announce()
    }
}
