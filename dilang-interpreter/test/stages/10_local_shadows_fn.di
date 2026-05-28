fn greet() -> Str { "from top-level fn" }

fn main() {
    // A local binding shadows the same-named top-level fn: the Call fast-path
    // must consult env before ctx.fns.
    let greet = || "from local closure"
    print(greet())
}
