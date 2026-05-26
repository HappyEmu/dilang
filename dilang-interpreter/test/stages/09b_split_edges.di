fn main() {
    // empty string splits to a single empty piece
    print("".split(",").len())                  // 1

    // separators at both boundaries yield empty pieces
    let bounded = ",a,".split(",")
    print(bounded.len())                         // 3
    print("[${bounded[0]}]")                     // []
    print("[${bounded[1]}]")                     // [a]
    print("[${bounded[2]}]")                     // []

    // multi-character separator
    let multi = "a::b::c".split("::")
    print(multi.len())                           // 3
    print(multi[0])                              // a
    print(multi[1])                              // b
    print(multi[2])                              // c
}
