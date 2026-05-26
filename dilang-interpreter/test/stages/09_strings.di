fn main() {
    let s = "GET /users/42 HTTP/1.1"

    print(s.len())                              // 22
    print(s.starts_with("GET"))                 // true
    print(s.contains("/users/"))                // true

    let parts = s.split(" ")
    print(parts.len())                          // 3
    print(parts[1])                             // /users/42

    let trimmed = "  hello  ".trim()
    print("[${trimmed}]")                       // [hello]
}
