fn main() {
    // The defer registered on the iteration that breaks still fires:
    // `Break_exn` propagates through the body's Scope, whose `Fun.protect`
    // runs the per-iteration defers on the way out.
    let mut i = 0
    loop {
        defer print("iter defer ${i}")
        if i >= 2 { break }
        i = i + 1
    }
    print("after loop")
}
