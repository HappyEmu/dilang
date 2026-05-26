fn main() {
    let nums = [3, 1, 4, 1, 5, 9, 2, 6]

    let mut max = nums[0]
    for n in nums {
        if n > max { max = n }
    }
    print(max)

    let mut doubled = []
    for n in nums {
        doubled.push(n * 2)
    }
    print(doubled.len())
    print(doubled[3])
}
