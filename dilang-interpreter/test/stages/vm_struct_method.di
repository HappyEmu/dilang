// DEC-020: value-method dispatch on a user struct. `p.dist()` / `p.scaled(10)`
// resolve against the impl methods on the constructed value — no `provide`, no
// capability dispatch. `self` is bound to the receiver; method bodies read
// `self.x` / `self.y`.

capability Metric { fn dist() -> I64 }

struct Point { x: I64, y: I64 }

impl Metric for Point {
    fn dist() -> I64 { self.x + self.y }
    fn scaled(k: I64) -> I64 { self.x * k }
}

fn main() {
    let p = Point { x: 3, y: 4 }
    print(p.dist())
    print(p.scaled(10))
}
