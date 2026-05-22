enum E {
    A(reason: Str)
    B
}

fn inner() {
    try {
        raise A("from inner")
    } catch {
        B -> print("caught B (unreachable)")
    }
}

fn main() {
    try {
        inner()
    } catch {
        A(why) -> print("outer caught A: ${why}")
    }
}
