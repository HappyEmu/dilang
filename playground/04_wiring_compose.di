// `with [ ... ]` with no body is a value of type Wiring.
// `...a(), ...b()` splats Wirings into the enclosing block.
// Later entries shadow earlier ones — overrides are just bindings
// placed after the spread entries they shadow.

fn base_runtime() -> Wiring {
    let rt = FiberRuntime(workers: 8)
    with [
        IO     <- rt                    @ 'Process
        Logger <- JsonLogger()          @ 'Process
        Clock  <- SystemClock()         @ 'Process
        IdGen  <- UuidV7Gen()           @ 'Process
    ]
}

fn pg_repos() -> Wiring {
    with [
        WriteDb  <- Postgres(IO.env("DB_URL") ?? panic("DB_URL")) @ 'Process
        UserRepo <- PgUserRepo {}                                 @ 'Process
        TaskRepo <- PgTaskRepo {}                                 @ 'Process
    ]
}

fn test_runtime() -> Wiring {
    with [
        IO     <- TestIO()                                          @ 'Process
        Logger <- TestLogger()                                      @ 'Process
        Clock  <- FixedClock(Instant.parse("2026-05-22T12:00:00Z")) @ 'Process
        IdGen  <- SeqIdGen([Uuid.parse("t1"), Uuid.parse("t2")])    @ 'Process
    ]
}

fn test_repos() -> Wiring {
    with [
        UserRepo <- InMemoryUserRepo() @ 'Process
        TaskRepo <- InMemoryTaskRepo() @ 'Process
    ]
}

fn main() {
    with [
        ...base_runtime(), ...pg_repos(),
    ] @ 'Process {
        serve(8080, router())
    }
}

// In tests, swap the production wiring for the test wiring; overrides go
// after the spread entries they replace.
test "task creation uses the fixed clock and seq id" {
    with [
        ...test_runtime(), ...test_repos(),
        IdGen <- SeqIdGen([Uuid.parse("only")]) @ 'Process,    // overrides test_runtime's IdGen
    ] @ 'Process {
        let task = create_task(Uuid.parse("u1"), CreateTaskInput { title: "x" })
        assert task.id == Uuid.parse("only")
        assert task.created_at == Instant.parse("2026-05-22T12:00:00Z")
    }
}
