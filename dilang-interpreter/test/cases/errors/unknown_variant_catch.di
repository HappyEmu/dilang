enum E { A }

fn main() {
    try {
        raise A
    } catch {
        Bogus -> print("never")
    }
}
