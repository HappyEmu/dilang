capability A { fn a(msg: Str) }
capability B { fn b(msg: Str) }
capability C { fn c(msg: Str) }

struct AImpl {}
impl A for AImpl {
    fn a(msg: Str) { print("A:${msg}") }
}

struct BImpl {}
impl B for BImpl {
    fn b(msg: Str) { A.a("from-B:${msg}") }
}

struct CImpl {}
impl C for CImpl {
    fn c(msg: Str) { B.b("from-C:${msg}") }
}

fn main() {
    with [
        A <- AImpl @ 'Process
        B <- BImpl @ 'Process
        C <- CImpl @ 'Process
    ] @ 'Process {
        C.c("hi")
        with [ A <- AImpl @ 'Process ] @ 'Process {
            C.c("inner")
        }
    }
}
