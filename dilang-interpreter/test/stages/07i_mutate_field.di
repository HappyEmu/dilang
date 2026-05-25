struct Tally { count: I64 }

fn main() {
    // Struct fields are refs (Stage 4). `AssignField` rewrites the ref in
    // place; subsequent reads observe the new value. No capability needed —
    // mutation through `name.field = rhs` works on any local impl value.
    //
    // NOTE — DEC-014 (Deferred): the binding below is `let` (not `let mut`)
    // and the v0 interpreter accepts the field mutation anyway, because the
    // receiver-root mut check isn't enforced yet. Under the eventual rule
    // (matching Rust), this test would need `let mut t = …`. Programs that
    // rely on this leniency will need the `mut` added when the rule lands.
    let t = Tally { count: 0 }
    t.count = t.count + 1
    t.count = t.count + 1
    t.count = t.count + 1
    print(t.count)
}
