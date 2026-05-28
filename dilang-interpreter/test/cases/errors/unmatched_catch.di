enum E { A, B }

fn inner() {
    try {
        raise A
    } catch {
        B -> print("never")
    }
}

fn main() {
    inner()
}
