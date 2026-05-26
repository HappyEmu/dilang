capability Logger { fn info(msg: Str) }

enum RetryError { GiveUp }

fn with_retry(times: I64, action: fn() -> I64) -> I64
    requires {Logger}
    raises   {GiveUp}
{
    let mut i = 0
    loop {
        try {
            return action()
        } catch {
            _ -> {
                i = i + 1
                Logger.info("attempt ${i} failed")
                if i >= times { raise GiveUp }
            }
        }
    }
}

fn main() {
    provide { Logger = StdoutLogger @ Process } in {
        let result = with_retry(3, || {
            Logger.info("attempting")
            42
        })
        print(result)
    }
}
