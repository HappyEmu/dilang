fn main() {
    // `try` is its own defer scope — distinct from the loop body. `break`
    // raises `Break_exn`; the try-body's Scope runs its defer via
    // `Fun.protect`, then the exception propagates past `catch` (which only
    // traps `Dilang_error`) into the enclosing `Loop` arm.
    loop {
        try {
            defer print("try cleanup")
            break
        } catch { _ -> print("never") }
    }
    print("out")
}
