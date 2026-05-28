capability Worker { fn run(name: Str) }

struct W {}

impl Worker for W {
    fn run(name: Str) {
        defer print("method cleanup ${name}")
        print("method body ${name}")
    }
}

fn outer() {
    defer print("outer fn cleanup")
    with [ Worker <- W @ 'Process ] @ 'Process {
        Worker.run("one")
        Worker.run("two")
        print("after both calls")
    }
}

fn main() {
    outer()
    print("after outer")
}
