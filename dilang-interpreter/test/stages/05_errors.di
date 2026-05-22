enum AppError {
    BadInput(reason: Str)
    NotFound
}

fn divide(a: I64, b: I64) -> I64 raises {AppError} {
    if b == 0 { raise BadInput("zero divisor") }
    a / b
}

fn find_user(id: Str) -> Str? {
    if id == "u1" { "Alice" } else { None }
}

fn main() {
    try {
        print(divide(10, 2))
        print(divide(10, 0))
    } catch {
        BadInput(reason) -> print("bad: ${reason}")
        NotFound         -> print("not found")
    }

    let name = find_user("u2") ?? return print("missing")
    print("got: ${name}")
}
