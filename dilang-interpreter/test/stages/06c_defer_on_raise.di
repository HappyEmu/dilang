enum E { Boom }

fn bang() raises {E} {
    defer print("d1 (registered first, fires last)")
    defer print("d2 (registered second, fires first)")
    print("before raise")
    raise Boom
}

fn main() {
    try {
        bang()
        print("unreachable")
    } catch {
        Boom -> print("caught Boom")
    }
}
