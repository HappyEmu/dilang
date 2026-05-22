// User code looks synchronous; there is no async/await coloring.
// Cancellation is structured: `with_cancel` gives you a token, and tripping
// it causes any operation suspended in the scope to raise `Cancelled` at
// its next suspension point. `with_timeout` is a thin stdlib helper over it.

// Race two HTTP fetches, take whichever wins. `select` fires the first arm,
// and the loser keeps running unless we tell it otherwise.
fn fastest_of(a: Url, b: Url) -> Response
    requires {IO, HttpClient}
    raises   {IoError}
{
    IO.with_cancel(|tok| {
        let fa = IO.spawn(|| HttpClient.get(a))
        let fb = IO.spawn(|| HttpClient.get(b))

        let winner = select {
            fa.await() -> fa.value()
            fb.await() -> fb.value()
        }

        tok.trip()    // cancel the loser
        winner
    })
}

// Bounded total wait — if the upstream is slow, return a default.
fn try_quick_lookup(id: Uuid) -> User
    requires {IO, UserRepo}
    raises   {NotFound}
{
    try with_timeout(500.millis) {
        UserRepo.find(id) ?? raise NotFound
    } catch {
        Timeout      -> raise NotFound
        DbFailure(_) -> raise NotFound
    }
}

// `defer` runs on every exit — normal, raised, cancelled, or panicked.
// `uncancellable` shields the COMMIT from interruption.
fn handle_payment(req: PaymentRequest) -> Receipt
    requires {IO, Logger, WriteDb}
    raises   {PaymentError}
{
    let conn = WriteDb.acquire()
    defer conn.release()
    defer Logger.info("payment handler exiting", {"req": req.id})

    let charge = try external_charge(req) catch _ -> raise PaymentError.UpstreamFailed

    uncancellable {
        // Once we've taken money from the card we must record it locally,
        // even if a shutdown signal trips cancellation mid-flight.
        conn.execute(sql"INSERT INTO payments (id, amount) VALUES (${req.id}, ${charge.amount})")
    }

    Receipt { id: charge.id, amount: charge.amount }
}
