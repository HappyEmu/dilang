fn main() {
    let xs = [10, 20, 30]
    xs[0] = 99
    print(xs[0])
    print(xs[1])
    xs[2] = xs[1] + xs[0]
    print(xs[2])
}
