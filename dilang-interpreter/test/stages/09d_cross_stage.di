fn main() {
    let csv = "a,b,c"

    // chain a string method into an array method (Stage 8)
    print(csv.split(",").len())                  // 3
    print(csv.split(",")[1])                     // b

    // iterate split pieces with a for-loop, trimming each
    let padded = " x , y , z "
    for p in padded.split(",") {
        print(p.trim())
    }
}
