capability A { fn a() }
capability B { fn b() -> Str }

struct AImpl {}
impl A for AImpl {
    requires {B}
    fn a() { print(B.b()) }
}

struct BImpl {}
impl B for BImpl {
    fn b() -> Str { "hi" }
}

struct UsesB {}
impl A for UsesB {
    fn a() { print(B.b()) }
}

fn main() {
    with [
        A <- UsesB @ 'Process,
        B <- BImpl @ 'Process
    ] @ 'Process {
        A.a()
    }
}
