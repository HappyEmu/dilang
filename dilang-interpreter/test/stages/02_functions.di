fn greet(name: Str) {
    print("hello, ${name}")
}

fn area(w: I64, h: I64) -> I64 {
    w * h
}

fn main() {
    greet("world")
    print(area(3, 4))
}
