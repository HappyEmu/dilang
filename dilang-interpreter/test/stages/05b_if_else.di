fn classify(n: I64) -> Str {
    let label = if n > 0 { "pos" } else { "non-pos" }
    label
}

fn announce(n: I64) {
    if n == 7 { print("lucky") }
}

fn main() {
    print(classify(3))
    print(classify(0))
    announce(7)
    announce(8)
    let m = if 1 + 1 == 2 { 10 } else { 20 }
    print(m)
}
