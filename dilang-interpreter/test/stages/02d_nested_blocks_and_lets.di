fn shadow(x: I64) -> I64 {
    let x = x + 1
    let x = x * 2
    let x = x + 100
    x
}

fn nested(x: I64) -> I64 {
    {
        let a = x + 1
        {
            let b = a + 1
            {
                let c = b + 1
                {
                    let d = c + 1
                    a + b + c + d
                }
            }
        }
    }
}

fn last_expr_value(x: I64) -> I64 {
    let _y = x * 100
    x + 1
}

fn early_in_branch(x: I64) -> Str {
    {
        return "from inner"
    }
    "unreachable"
}

fn main() {
    print(shadow(0))                         // (((0+1)*2)+100) = 102
    print(shadow(5))                         // (((5+1)*2)+100) = 112
    print(nested(10))                        // a=11,b=12,c=13,d=14 -> 50
    print(last_expr_value(7))                // 8
    print(early_in_branch(0))                // from inner
}
