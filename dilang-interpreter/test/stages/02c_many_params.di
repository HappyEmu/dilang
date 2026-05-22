// Many parameters, layered calls, intermediate lets — no recursion since
// Stage 3 has no `if` to terminate a base case.

fn add8(a: I64, b: I64, c: I64, d: I64, e: I64, f: I64, g: I64, h: I64) -> I64 {
    a + b + c + d + e + f + g + h
}

fn average(a: I64, b: I64, c: I64, d: I64, e: I64) -> I64 {
    let s = a + b + c + d + e
    s / 5
}

fn weird(a: I64, b: I64) -> I64 {
    {
        {
            {
                let t = a * 10 + b
                return t
            }
        }
    }
    999
}

fn passthrough(x: Str) -> Str {
    x
}

fn main() {
    print(add8(1, 2, 3, 4, 5, 6, 7, 8))                              // 36
    print(average(10, 20, 30, 40, 50))                               // 30
    print(weird(7, 3))                                               // 73
    print(passthrough("hi"))                                         // hi
    print(add8(add8(1,1,1,1,1,1,1,1), 2, 3, 4, 5, 6, 7, 8))          // 43
}
