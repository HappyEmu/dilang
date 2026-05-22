// A transaction is a Transaction-scoped capability whose Lifecycle
// issues BEGIN/COMMIT/ROLLBACK on entry/exit of the `provide` block.
// There is no `transaction` keyword and no macro — the shape is the
// same as every other scoped capability.

scope Transaction

capability DbTx @ Transaction {
    fn execute(sql: Sql)        raises {DbError}
    fn query(sql: Sql) -> Rows  raises {DbError}
}

struct PgTransaction { conn: Connection }

impl DbTx for PgTransaction {
    fn execute(sql: Sql)       raises {DbError} { self.conn.execute(sql) }
    fn query(sql: Sql) -> Rows raises {DbError} { self.conn.query(sql) }
}

impl Lifecycle for PgTransaction {
    requires {Logger}

    fn start() raises {StartupError} {
        self.conn.execute("BEGIN")
    }

    fn shutdown(exit: ExitReason) {
        match exit {
            Normal    -> self.conn.execute("COMMIT")
            Raised(_) -> self.conn.execute("ROLLBACK")
            Panicked  -> {
                self.conn.execute("ROLLBACK")
                Logger.error("transaction panicked", {})
            }
        }
    }
}

// The block exits normally → COMMIT runs.
// Any raise out of the block → ROLLBACK runs.
pub fn transfer_tasks(from: Uuid, to: Uuid)
    requires {WriteDb, Logger}
    raises   {DbFailure}
{
    provide @ Transaction {
        DbTx = PgTransaction { conn: WriteDb.acquire() } @ Transaction
    } in {
        try {
            DbTx.execute(sql"UPDATE tasks SET owner = ${to} WHERE owner = ${from}")
            DbTx.execute(sql"INSERT INTO audit (event, at) VALUES ('transfer', NOW())")
        } catch DbError(e) -> raise DbFailure(e)
    }
}
