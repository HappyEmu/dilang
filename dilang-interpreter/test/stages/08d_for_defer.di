fn main() {
    let xs = [1, 2, 3]
    for x in xs {
        defer print("end ${x}")
        print("body ${x}")
    }
    print("after loop")
}
