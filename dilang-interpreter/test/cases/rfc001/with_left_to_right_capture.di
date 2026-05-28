capability A { fn a() }
capability B { fn b() }

struct AImpl {}
impl A for AImpl {
    fn a() { print("a") }
}

struct BImpl {}
impl B for BImpl {
    fn b() {
        A.a()
        print("b")
    }
}

fn main() {
    with [
        A <- AImpl
        B <- BImpl
    ] @ 'Process {
        B.b()
    }
}
