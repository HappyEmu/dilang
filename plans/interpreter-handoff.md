# Handoff: after value-method dispatch on `VImpl` (post-Stage-11)

This is a **knowledge handover**, not a plan. Landed and green since Stage 11:
value-method dispatch on `VImpl` (DEC-020), short-circuit `&&`/`||` (DEC-021),
inherent impls `impl Type { … }` (DEC-022), the array type `[T]` in type
position (no DEC), and the Milestone 11.5 router demos (`service.di` plus a
graceful-shutdown approximation `graceful.di`). It records what changed and the
load-bearing facts the next planner needs — it does **not** plan the next stage.
The previous (post-Stage-11) handoff has been replaced by this one.

## Where we are

Stages 1–11 plus the value-method-dispatch work are landed and green
(**130 tests**: 120 prior + 5 `valuemethod` stage fixtures + 2 router smoke
tests + 3 new `errors` cases). `dune build && dune runtest` (run from
`dilang-interpreter/`) is the gate. Repo layout: `dilang-interpreter/{lib,bin,test}`
for code; `plans/` and `docs/` at repo root.

Source of truth, in order of precedence:
- `plans/interpreter.md` — **Milestone 11.5** is now shipped (route-table demo,
  `test/programs/router/service.di`; plus a graceful-shutdown approximation,
  `programs/router/graceful.di`); **Stage 12 — Scopes** (`@ Request`) at
  line ~1175 is the next planned stage.
- `docs/lang/syntax.md`, `docs/lang/design.md`, `docs/lang/decisions.md`
  (decisions now run through **DEC-022**).

## What this change shipped

**Value-method dispatch on `VImpl` is the headline (DEC-020).** Previously
`value_method_dispatch` (`eval.ml`) handled only `[T]` and `Str`; any `VImpl`
(user struct / host impl value) fell through to *"method … not supported on this
value"*, so user-struct/impl methods were reachable **only** through capability
dispatch (`cap_call`). That gap — flagged as the biggest structural finding of
Stage 11 — is now closed:

- A `VImpl` arm in `value_method_dispatch` resolves `name` against `iv.methods`.
  `DUser m` runs through the shared helper `call_impl_method ctx iv m args
  ~caps:ctx.caps ~bind_self:true`; `DHost f` calls the host fn. `cap_call`'s
  `DUser` arm was refactored to call the **same** helper with
  `~caps:impl.cap_env ~bind_self:(impl.fields <> [])` — behavior unchanged.
- **Caller-caps, deliberately.** Value-dispatched user methods run with the
  *caller's* caps (`ctx.caps`), unlike `cap_call` (impl's captured `cap_env`),
  because a plain `let p = Point{…}` value was never wired through `provide`.
  Proven by `test/stages/vm_method_calls_cap.di` (a struct built outside a
  `provide`, its method calls `Logger.info` resolved at the call site).
- **Rust method/field rule.** `s.f(args)` is always an impl method; a field
  holding a function is called `(s.f)(args)`. Same-name field+method is allowed.
  Missing-method error hints `"field f on T is not a method; call it as
  (x.f)(...)"` when a field of that name exists, else `"no method f on T"`.

**`r.handler(req)` blocker resolved.** The router needs to call a function held
in a struct field. `(r.handler)(req)` now parses (new general call form
`(expr)(args)` in `atom`/`head_atom`) and runs (eval's existing general `Call`
arm). The no-paren `r.handler(req)` is — correctly — a method call now, and
errors with the field-vs-method hint.

**Short-circuit `&&` / `||` (DEC-021).** Dedicated `And`/`Or` AST nodes (not
`bin_op`, since `eval_binop` takes pre-evaluated operands). `||` lexes as one
`BARBAR`, shared with the zero-arg lambda `||body`; spaced `| |body` still lexes
as two `PIPE`s. Precedence ladder (loosest first): `BARBAR`, `AMPAMP`,
`QMARK_QMARK`, comparisons, `+`/`-`, `*`/`/`.

**Array type `[T]` in type position.** `type_name` gained `LBRACKET type_name
RBRACKET` (stringified placeholder; types are erased at runtime), so
`fn route(req: Request, table: [Route])` parses. This was already documented in
syntax §Arrays as the array type — the parser just hadn't implemented it. It
added **no** new conflicts (LBRACKET after `:`/`->` is unambiguous). No DEC: it
brings the parser in line with already-documented syntax.

**Inherent impls (DEC-022).** A bare `impl Type { fn ... }` (no `for`, no
interface) declares a type's own methods, reached by receiver via value dispatch.
A second `decl` production in `parser.mly` (`IMPL IDENT LBRACE … RBRACE` →
`caps = []`); `caps`/`priv_requires` are never read at runtime so empty caps
needs no plumbing. Disambiguates one token after `IMPL IDENT` (`LBRACE` vs
`FOR`/`PLUS`) — **zero** new conflicts. This removed the "marker capability"
hack from value types: `Router` is now `impl Router { … }`. Note `trait` is
**still unimplemented** (only `capability` exists); inherent impls are the
no-interface form, orthogonal to the eventual trait (named-interface-by-receiver)
form. Pinned by `vm_inherent_impl.di`.

**Milestone 11.5 router demo landed** at `test/programs/router/service.di`: a
`Route` struct (with a `handler: fn(Request) -> Response` field), a `route(req,
table: [Route])` fn matching method + path-prefix with `&&`, and
`(r.handler)(req)` to invoke the matched handler. Driven by the `router_demo`
test (`run_test.ml`) over four requests (matched GET, body-echoing POST, unknown
path, wrong method) through the same fork fixture as the Stage 11 HTTP tests.
**Note:** dilang has no `;` statement separator — block statements are
newline/adjacency-separated; the plan's `;`-joined handler body was rewritten.

## The `HttpServer`-as-value question is now UNBLOCKED

Stage 11's open design question (keep `HttpClient` as a capability; revisit
`HttpServer` toward a `Net`-authority capability + server/`Router`-as-value)
named "once value-method dispatch on `VImpl` exists" as its precondition. **That
precondition is now met.** `server.serve()` / `listener.accept()` on a value now
have a code path. `programs/router/graceful.di` (the `router_graceful` test) is a
first approximation of design §4.8: a `Router` value with inherent-impl
builder/dispatch methods and `defer`-based deterministic teardown, with the
bounded `--max-requests` loop standing in for shutdown. It is graceful *in spirit*
only — there is still no signal handling, no concurrent request handling, and
nothing to drain (the server is sequential). Genuine graceful shutdown needs the
reshaping below **plus** Stage 15 (concurrency / in-flight `Group`) and Stage 16
(`with_timeout` / cancellation). The substance, unchanged and still un-DEC'd:
- `HttpClient` is a clean capability (ambient authority, short effects) — keep.
- `HttpServer` is the weaker fit: `serve(port, handler)` is long-lived,
  blocking, stateful with a lifecycle. The principled alternative is a `Net`
  *authority* capability (`listen(port) -> Listener`) with `Listener` / server /
  `Router` as **structs + impl**. The router demo is already value-shaped.
- The Eio guts stay a host impl either way; the capability-vs-value choice only
  changes the *interface*. Write a DEC when it's decided.

## Carry-forward facts (still load-bearing)

- **dilang comments are `//` only** — no `(* *)`; an OCaml comment in a `.di`
  file is a parse error. **No `;` statement separator** — newline/adjacency.
- **`Logger` is not in the prelude** — only the HTTP caps are. Any service
  program calling `Logger.info` must `capability Logger { fn info(msg: Str) }`
  itself. `StdoutLogger` is a host *impl*, always registered, but a host impl
  needs its capability *declared* for `MethodCall` to route to cap dispatch.
- **Bare construction, DEC-009 unchanged** — `Foo @ Process`, not `Foo()`.
  `interpreter.md` examples that use `Foo()` construction, `catch _ { … }`, or
  `;` separators are aspirational; re-derive every program from the grammar and
  run it before pinning output.
- **`requires` precedes `raises`** in fn/cap signatures.
- **No module cycle:** `eval.ml` opens only `Ast` and `Value`, so
  `host_builtin.ml` calls `Eval.call_value` / `Eval.call_impl_method` and raises
  `Eval.Dilang_error` freely.
- **`impl_decl.caps` / `priv_requires` are never read at runtime** — only
  `for_ty` (to index `impls_by_ty` in `driver.ml`) and `methods` (collected by
  `methods_for_ty`, which rejects duplicate names *across all impl blocks for a
  type*, inherent + `for`). This is why inherent impls (DEC-022) needed no eval
  plumbing — `caps = []` is inert. A future row-checker is where those fields
  start mattering. Methods from an inherent impl and from `impl Cap for Type`
  blocks all merge onto the same struct constructor.
- **Prefix-route catch-all gotcha.** The router demos match on `path.starts_with(prefix)`,
  so a `prefix: "/"` route catches *every* path — `GET /nope` hits the root
  handler, not the 404. The `router_graceful` test's 404 case therefore uses an
  unbound `POST /missing` (no route has the POST+`/missing` combination), not a
  GET. A real router would need longest-prefix / exact-match precedence; the demo
  deliberately keeps first-match-wins.
- **The fork-based HTTP fixture has sharp edges** (`run_test.ml`): child runs
  `Driver.run_file ~max_requests` with stdout dup2'd to a pipe and exits via
  `Unix._exit`; parent retries the **TCP connect** (send nothing until connect
  succeeds) to wait for the listener; `waitpid` must **retry on `EINTR`**; budget
  `max_requests` to exactly the number of requests sent (each raw send =
  one served request). The reusable driver is now `with_server ~prog`
  (`with_http_server ~service` is a thin wrapper); `http_get_raw` /
  `http_post_raw` send one request each. HTTP request bodies are read only when
  `Content-Length` is present (the GET-deadlock fix); responses read-to-EOF.
- **Manual router smoke:** `dune exec dilang -- run
  test/programs/router/service.di --max-requests 4` in the background, then
  `curl localhost:18080/health` → `ok`, `curl -XPOST -d hi
  localhost:18080/echo` → `hi`, `curl localhost:18080/nope` → `no route`; server
  exits clean after 4 requests. (Port is **18080**, matching the HTTP fixtures —
  not 8080.)
- **DEC entries are cheap; keep writing them.** This round added DEC-020
  (value-method dispatch), DEC-021 (short-circuit operators), and DEC-022
  (inherent impls). The array type `[T]` got no DEC — it just implements
  already-documented syntax (§Arrays).
- **`trait` is still unimplemented.** Only `capability` exists as an interface
  decl; there is no `trait` keyword/parser/AST node (despite syntax §3 and
  DEC-008 describing traits). Value types use inherent impls (DEC-022) for their
  own methods. A real `trait` — named interface resolved by receiver, with
  default-method bodies — is a separate unbuilt feature; value-method dispatch
  (DEC-020) is the runtime mechanism it would reuse.

## Out of scope (per `plans/interpreter.md`)

Per-request scoping (`@ Request`) — Stage 12. DB pool + `Lifecycle` — Stage 13.
Concurrent request handling (`EioHttpServer`) — Stage 15. Per-request timeouts —
Stage 16. Streaming/chunked/SSE — Stage 17. HTTPS, HTTP/2, websockets — not on
the roadmap. Header ergonomics deferred until a tuple/map value exists
(DEC-019). Row-polymorphic generics on function types remain deferred to the
type-checker phase.

-----

## Addendum (standing) — parser conflict budget

The committed parser now sits at **12** conflict states (`lib/parser.conflicts`),
up deliberately from the prior **7**. All are shift/reduce, all resolved by the
desired default-shift. Three families:

1. **General-call-form `atom . LPAREN`** (7 states). The new `(expr)(args)`
   production overlaps with: the bare `IDENT LPAREN` call rule (default-shift
   keeps `print(x)`/`Some(1)` on it); `expr -> atom` as a block statement;
   `dot_tail` empty vs `LPAREN` (default-shift makes `x.f()` a **method call**,
   not field-then-call); `break`-payload and `raise`-payload atoms extending
   into a call. Mirrored in `head_atom` for `if`/`while`/`for` heads.
2. **`||`-operator vs zero-arg-lambda-statement** (3 states). After an `expr` in
   statement position (`let x = a`, bare `expr`, `expr = rhs`), lookahead
   `BARBAR` default-shifts the or-operator into the expression rather than
   starting a new `||body` lambda statement (`let x = a || b` = `let x = (a || b)`).
3. **`BARBAR`/`AMPAMP` joining pre-existing families**: the `break`-payload state
   (a `||body` lambda can be a payload) and the Stage-10 lambda-body-absorbs-
   trailing-operator state (`|x| x && y` = `|x| (x && y)`).

The array-type `[T]` and inherent-impl (`impl Type { … }`) productions each
added **zero** conflicts. Exact state numbers
shift across regens; consult `lib/parser.conflicts` for the current set rather
than memorising IDs. Treat **12** as the baseline and `diff` against it on every
parser change — if it moved, you touched the grammar.
