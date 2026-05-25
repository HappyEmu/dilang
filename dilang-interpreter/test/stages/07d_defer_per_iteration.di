fn main() {
    // DEC-012: each `{ ... }` is a fresh defer frame. The `while` body is a
    // Scope, so the defer registered inside fires at end-of-iteration.
    //
    // Gotcha: defer bodies evaluate against the live env at fire time, not at
    // registration time. The `i = i + 1` runs *inside* the iteration scope —
    // so by the time the defer fires, `i` is already 1 (then 2, 3). Pre-bind
    // to an immutable local if you want capture-at-registration semantics.
    let mut i = 0
    while i < 3 {
        defer print("end iter ${i}")
        print("body ${i}")
        i = i + 1
    }
    print("done")
}
