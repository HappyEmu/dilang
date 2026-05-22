enum SrcError {
    DbError(msg: Str)
}

enum BoundaryError {
    DbFailure(msg: Str)
}

fn raw_query() -> Str raises {SrcError} {
    raise DbError("connection refused")
}

fn boundary() -> Str raises {BoundaryError} {
    try raw_query() catch {
        DbError(e) -> raise DbFailure(e)
    }
}

fn main() {
    try {
        let s = boundary()
        print(s)
    } catch {
        DbFailure(m) -> print("boundary caught: ${m}")
    }
}
