fn main() {
    // Multiplication binds tighter than addition.
    print(1 + 2 * 3)                 // 7
    print(2 * 3 + 4)                 // 10
    print((1 + 2) * 3)               // 9

    // Left-associative subtraction.
    print(10 - 3 - 2)                // 5
    print(10 - (3 - 2))              // 9

    // Integer division floors toward zero (Int64 semantics).
    print(7 / 2)                     // 3
    print(0 - 7 / 2)                 // -3
    print((0 - 7) / 2)               // -3

    // Mixed precedence sanity.
    print(2 + 3 * 4 - 5)             // 9
    print(20 / 4 / 5)                // 1
    print(2 * 3 * 4 * 5 * 6)         // 720

    // Comparison precedence is below arithmetic.
    print(1 + 2 == 3)                // true
    print(2 * 3 != 5)                // true
    print(10 - 1 >= 9)               // true
    print(2 * 2 <= 3)                // false

    // Deep parenthesisation should not blow up.
    print(((((((((1 + 2)))))))))     // 3
}
