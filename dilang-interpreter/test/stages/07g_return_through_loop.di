fn driver() -> Str {
    defer print("fn defer")
    let mut i = 0
    loop {
        defer print("loop defer ${i}")
        if i >= 1 { return "done" }
        i = i + 1
    }
}

fn main() {
    let r = driver()
    print("caller got: ${r}")
}
