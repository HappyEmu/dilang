// DEC-020: a struct field holding a function value is NOT reachable as
// `b.f(args)` (that is a method call — see vm_field_not_method error case).
// Invoke it with the parenthesised call form `(b.f)(args)`: `b.f` is a
// FieldGet yielding the function value, then `(...)(args)` is a general call.
// Works whether the field holds a closure or a bare top-level fn value.

struct Box { f: fn(I64) -> I64 }

fn add100(n: I64) -> I64 { n + 100 }

fn main() {
    let b = Box { f: |n| n + 1 }
    print((b.f)(21))
    let b2 = Box { f: add100 }
    print((b2.f)(5))
}
