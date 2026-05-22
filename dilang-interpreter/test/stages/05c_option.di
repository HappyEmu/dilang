enum AppError {
    BadInput(reason: Str)
}

struct Box { contents: Str? }

fn boxed(s: Str) -> Box? {
    Some(Box { contents: Some(s) })
}

fn emptyBox() -> Box? {
    Some(Box { contents: None })
}

fn loud(s: Str) -> Str {
    print("evaluating fallback")
    s
}

fn main() {
    // Some short-circuits — RHS not evaluated.
    let a = Some("hi") ?? loud("never")
    print(a)

    // None falls through; RHS evaluated.
    let b = None ?? loud("fallback")
    print(b)

    // ?? on the result of a struct field that's Option.
    let bx = Box { contents: None }
    let c = bx.contents ?? "absent"
    print(c)

    // ?.field through nested options, flattened per §12.1.
    let outer = boxed("payload")
    let v = outer?.contents ?? "empty"
    print(v)

    let outer2 = emptyBox()
    let v2 = outer2?.contents ?? "empty"
    print(v2)

    // None ?? raise caught by outer try.
    try {
        let x = None ?? raise BadInput("nothing")
        print(x)
    } catch {
        BadInput(why) -> print("caught: ${why}")
    }

    // None ?? return — returns from main, suppressing further prints.
    let _last = None ?? return print("returning")
    print("not reached")
}
