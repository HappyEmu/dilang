capability Counter {
    fn bump()
    fn value() -> I64
}

struct Tally { count: I64 }

impl Counter for Tally {
    // `self.field = rhs` inside an impl method. Here `self` resolves to a
    // VImpl whose fields are the same refs the constructor produced, so
    // writes through `self` survive across dispatches — the next
    // Counter.value() observes the cumulative count.
    fn bump() { self.count = self.count + 1 }
    fn value() -> I64 { self.count }
}

fn main() {
    provide { Counter = Tally { count: 0 } @ Process } in {
        Counter.bump()
        Counter.bump()
        Counter.bump()
        print(Counter.value())
    }
}
