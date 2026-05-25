enum AppError {
    BadInput(reason: Str)
}

fn handle(name: Str) {
    defer print("cleanup ${name}")
    print("doing ${name}")
}

fn risky() raises {AppError} {
    defer print("risky cleanup")
    raise BadInput("oops")
}

fn main() {
    handle("a")
    handle("b")
    try risky() catch {
        BadInput(_) -> print("caught")
    }
}
