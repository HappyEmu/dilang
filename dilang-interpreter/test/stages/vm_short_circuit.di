// DEC-021: short-circuit `&&` / `||`. Each operand prints its tag when
// evaluated, so the output proves the RHS is skipped exactly when the LHS
// decides the result.

fn t(tag: Str) -> Bool { print(tag) true }
fn f(tag: Str) -> Bool { print(tag) false }

fn main() {
    print(f("a") && t("skip1"))
    print(t("b") || t("skip2"))
    print(t("c") && t("d"))
    print(f("e") || f("g"))
}
