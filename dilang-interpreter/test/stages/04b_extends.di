capability ReadDb { fn query(sql: Str) -> Str }
capability WriteDb extends ReadDb { fn execute(sql: Str) }

struct EchoDb {}
impl ReadDb + WriteDb for EchoDb {
    fn query(sql: Str) -> Str { "[result: ${sql}]" }
    fn execute(sql: Str) { print("[exec: ${sql}]") }
}

fn show() requires {ReadDb} {
    print(ReadDb.query("SELECT 1"))
}

fn main() {
    provide { WriteDb = EchoDb @ Process } in { show() }
}
