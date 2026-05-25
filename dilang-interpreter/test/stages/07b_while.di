fn main() {
    let mut n = 0
    while n < 3 {
        print("tick ${n}")
        n = n + 1
    }
    print("after ${n}")
    // `while` is a statement (DEC-013): it has no value. Re-evaluating the
    // condition each iteration is verified by the loop terminating cleanly
    // once n reaches 3.
    let mut k = 5
    while k > 0 { k = k - 1 }
    print("k=${k}")
}
