fn main() {
    let f = |x| {
        defer print("deferred")
        print("body ${x}")
        x
    }
    print(f(5))
    print("after")
}
