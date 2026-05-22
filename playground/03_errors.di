// Errors live in the `raises` row, parallel to `requires`.
// There is no Result type, no `?` operator. Crossing a domain boundary
// means catching the low-level variant and raising a domain one — explicitly.

enum ParseError { Empty; BadFormat(at: U32) }
enum DbError { ConnectionLost; ConstraintViolation(name: Str) }

// A domain error that hides DB internals from upstream callers.
enum UserError {
    NotFound
    InvalidEmail(reason: Str)
    Persistence    // wraps any DbError after re-tagging
}

fn parse_email(raw: Str) -> Email
    raises {ParseError}
{
    if raw.is_empty() { raise ParseError.Empty }
    let at = raw.index_of('@') ?? raise ParseError.BadFormat(at: 0)
    Email { local: raw.slice(0, at), host: raw.slice(at + 1, raw.len()) }
}

// Re-tag at the boundary: the public signature mentions only UserError.
pub fn register(raw_email: Str) -> User
    requires {UserRepo, IdGen}
    raises   {UserError}
{
    let email = try parse_email(raw_email) catch {
        ParseError.Empty           -> raise UserError.InvalidEmail("empty")
        ParseError.BadFormat(at)   -> raise UserError.InvalidEmail("bad format at ${at}")
    }

    let user = User { id: IdGen.next(), email, name: "" }

    try UserRepo.insert(user) catch {
        DbError.ConstraintViolation("users_email_uniq") -> raise UserError.InvalidEmail("taken")
        DbError(_)                                      -> raise UserError.Persistence
    }

    user
}

// `raise X` has type Never, so it composes with `??`.
fn require_user(id: Uuid) -> User
    requires {UserRepo}
    raises   {UserError}
{
    try UserRepo.find(id) catch DbError(_) -> raise UserError.Persistence
        ?? raise UserError.NotFound
}
