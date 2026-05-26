fn main() {
    let s = "hello world"

    print(s.contains("o w"))                     // true
    print(s.contains("xyz"))                     // false
    print(s.contains(""))                        // true

    print(s.starts_with("hello"))                // true
    print(s.starts_with("world"))                // false

    print(s.ends_with("world"))                  // true
    print(s.ends_with("hello"))                  // false
}
