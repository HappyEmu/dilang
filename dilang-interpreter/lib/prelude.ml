(* Stage 11 prelude — a TEMPORARY STOPGAP.

   This is *not* a language feature. The string below is ordinary dilang source,
   parsed by exactly the same `Driver.parse_string` path as a user program and
   merged (prepended) into the user's decl list before `build_tables`. It exists
   only because dilang has no module system and no standard library yet: there
   is currently nowhere else to declare the capability *interfaces* and data
   *types* that the Stage 11 host impls (`BlockingHttpServer` /
   `BlockingHttpClient`, defined in OCaml in `host_builtin.ml`) implement
   against.

   Nothing here is privileged. `HttpServer`/`HttpClient` become entries in
   `cap_decls`/`ext_of`, `Request`/`Response` become `user_constructors`, and
   `HttpError` flows through the ordinary user-enum loop in `driver.ml` — the
   same as if the user had typed these declarations themselves.

   When a real module system + stdlib land, this file disappears: these
   declarations move into an importable stdlib module and stop being injected.
   See DEC-018. Headers are intentionally absent from `Request`/`Response`
   (DEC-019: no tuple/map value model yet). *)

let source = {dilang|
capability HttpServer { fn serve(port: I64, handler: fn(Request) -> Response) }

capability HttpClient {
    fn get(url: Str) -> Response raises {HttpError}
    fn post(url: Str, body: Str) -> Response raises {HttpError}
}

struct Request  { method: Str, path: Str, body: Str }
struct Response { status: I64, body: Str }

enum HttpError {
    ConnectionFailed(reason: Str)
    BadStatus(code: I64)
    InvalidUrl
}
|dilang}
