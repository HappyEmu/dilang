fn inner() {
    defer print("inner cleanup")
    print("inner body")
}

fn outer() {
    defer print("outer cleanup")
    print("outer before inner")
    inner()
    print("outer after inner")
}

fn main() {
    outer()
    print("main done")
}
