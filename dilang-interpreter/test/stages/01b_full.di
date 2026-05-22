// Stage 1 stress test: every construct the interpreter can run at this stage.
//   - operator precedence and left-associativity
//   - integer division, parens, nested blocks-as-expressions
//   - bool literals and all comparison operators
//   - string literals and string equality
//   - shadowing via let
//   - line comments

fn main() {
    // Operator precedence: * binds tighter than +
    print(1 + 2 * 3)                  // 7
    print((1 + 2) * 3)                // 9

    // Left-associativity of - and /
    print(20 - 3 - 2)                 // 15
    print(20 / 4 / 2)                 // 2

    // Integer division truncates toward zero
    print(100 / 3)                    // 33
    print(7 / 2)                      // 3

    // Bindings, arithmetic chains
    let a = 10
    let b = 20
    let c = a + b
    print(c)                          // 30
    print(c * c)                      // 900
    print((a + b) * (b - a))          // 300

    // All six comparison ops returning bool
    print(a <  b)                     // true
    print(a >  b)                     // false
    print(a <= 10)                    // true
    print(b >= 21)                    // false
    print(a == b)                     // false
    print(c != 0)                     // true

    // Block-as-expression: last expr in the block is the value
    let nested = {
        let x = 5
        let y = 6
        x * y
    }
    print(nested)                     // 30

    // Negatives via subtraction (no unary minus at this stage)
    let neg = 0 - 7
    print(neg)                        // -7
    print(neg < 0)                    // true
    print(0 - neg)                    // 7

    // String literals and string equality
    print("hello")
    print("world")
    print("abc" == "abc")             // true
    print("abc" == "xyz")             // false

    // Boolean literals
    print(true)
    print(false)
    print(true == true)               // true
    print(true == false)              // false

    // Shadowing: inner let rebinds the name for the rest of the block
    let a = 99
    print(a)                          // 99

    // Mut declarations are accepted (reassignment is Stage 13)
    let mut counter = 0
    print(counter)                    // 0
}
