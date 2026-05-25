fn main() {
    // DEC-013: `loop` is an expression; the result is `break v`'s payload.
    let mut i = 0
    let r = loop {
        if i == 4 { break (i * 10) }
        i = i + 1
    }
    print("r=${r}")

    // `break;` (no value) yields VUnit; a statement-position `loop` quietly
    // discards it.
    let mut k = 0
    loop {
        if k >= 2 { break }
        print("k=${k}")
        k = k + 1
    }
    print("after")
}
