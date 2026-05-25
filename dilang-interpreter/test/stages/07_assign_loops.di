fn main() {
    let mut i   = 0
    let mut sum = 0
    let total = loop {
        if i >= 10 { break sum }
        sum = sum + i
        i = i + 1
    }
    print(total)

    let mut n = 5
    while n > 0 {
        print(n)
        n = n - 1
    }
    print("done")
}
