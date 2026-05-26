fn main() {
    let g = |x| x + 1
    print(g(10))

    let add = |a, b| { a + b }
    print(add(3, 4))

    // zero-param lambda
    let answer = || 42
    print(answer())

    // fully annotated lambda: param types + return type (erased at runtime)
    let typed = |x: I64, y: I64| -> I64 { x * y }
    print(typed(6, 7))
}
