fn main() {
    // `continue` in `while`: skip the rest of the body but re-evaluate the
    // condition (so the loop still terminates on its own).
    let mut i = 0
    while i < 5 {
        i = i + 1
        if i == 3 { continue }
        print("w ${i}")
    }
    print("--")
    // `continue` in `loop`: jump back to the top immediately. Use `break` to
    // exit so the test still terminates.
    let mut j = 0
    loop {
        j = j + 1
        if j == 2 { continue }
        if j >= 4 { break }
        print("l ${j}")
    }
    print("end ${j}")
}
