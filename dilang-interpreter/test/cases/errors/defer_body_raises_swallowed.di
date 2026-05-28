enum E { Boom }

fn noisy() {
    defer print("d1")
    defer raise Boom
    print("body")
}

fn main() {
    noisy()
    print("after")
}
