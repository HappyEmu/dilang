fn three() {
    defer print("first registered")
    defer print("second registered")
    defer print("third registered")
    print("body")
}

fn main() {
    three()
    print("after")
}
