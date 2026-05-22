fn main() {
    // Int equality
    print(1 == 1)                      // true
    print(1 == 2)                      // false
    print(0 - 5 == 0 - 5)              // true

    // Str equality
    print("hi" == "hi")                // true
    print("hi" == "ho")                // false
    print("" == "")                    // true

    // Bool equality
    print(true == true)                // true
    print(true == false)               // false
    print(false != true)               // true

    // Comparisons
    print(1 < 2)                       // true
    print(2 < 1)                       // false
    print(2 <= 2)                      // true
    print(3 >= 3)                      // true
    print(0 - 1 < 0)                   // true

    // Escape sequences in strings
    print("tab\there")                 // tab<TAB>here
    print("quoted: \"hello\"")         // quoted: "hello"
    print("backslash: \\")             // backslash: \
    print("newline:\nafter")           // multiline

    // Empty + long string
    print("")                          // (blank line)
    print("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
}
