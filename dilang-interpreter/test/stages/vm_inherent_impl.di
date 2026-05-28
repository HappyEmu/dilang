// DEC-022: inherent impl — `impl Type { ... }` declares a type's own methods
// with no capability/trait interface. The methods reach the value through
// value-method dispatch (DEC-020). Here a builder method mutates and returns
// `self`, so `.push_one(..)` chains; `total()` reads `self.items`. Because
// push returns the same value (shared array ref), `st` itself accumulates.

struct Stack { items: [I64] }

impl Stack {
    fn push_one(x: I64) -> Stack {
        self.items.push(x)
        self
    }
    fn total() -> I64 {
        let mut s = 0
        for v in self.items { s = s + v }
        s
    }
}

fn main() {
    let st = Stack { items: [] }
    print(st.push_one(10).push_one(20).push_one(30).total())
    print(st.total())
}
