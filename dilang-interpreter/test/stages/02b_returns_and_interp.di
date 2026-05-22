fn sum3(a: I64, b: I64, c: I64) -> I64 {
    a + b + c
}

fn early(x: I64) -> I64 {
    {
        {
            return x * 2
        }
    }
    999
}

fn label(name: Str, n: I64) -> Str {
    "${name} = ${n}, doubled = ${n + n}"
}

fn main() {
    print(sum3(1, sum3(2, 3, 4), 5))
    print(early(7))
    print(label("x", 21))
    print("literal: \${not interpolated}")
    print("nested: ${label("y", sum3(1, 2, 3))}")
}
