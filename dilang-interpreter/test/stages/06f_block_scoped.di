// Each surface `{ ... }` is its own defer scope (DEC-012):
//   - if-branch body
//   - with body
//   - bare block expression
// All three show the defer firing as the block exits, before the surrounding
// code continues.

capability Logger { fn info(msg: Str) }

fn show_if_scope(n: I64) {
    if n > 0 {
        defer print("end of if-branch")
        print("inside if")
    }
    print("after if")
}

fn show_with_scope() {
    with [ Logger <- StdoutLogger @ 'Process ] @ 'Process {
        defer print("end of with body")
        Logger.info("inside with")
    }
    print("after with")
}

fn show_bare_block() {
    let x = {
        defer print("end of bare block")
        42
    }
    print("after bare block, x = ${x}")
}

fn main() {
    show_if_scope(1)
    print("---")
    show_with_scope()
    print("---")
    show_bare_block()
}
