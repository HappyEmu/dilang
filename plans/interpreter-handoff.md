# Handoff: after value-method dispatch on `VImpl` (post-Stage-11)

A **knowledge handover**, not a plan. It records the load-bearing facts the next
planner needs; it does not plan the next stage. The "how it landed" narration has
been pruned — that detail now lives in DEC-020/021/022 and the code.

## Where we are

Stages 1–11 plus value-method-dispatch work are landed and green (**138 tests**).
`dune build && dune runtest` (from `dilang-interpreter/`) is the gate. Layout:
`dilang-interpreter/{lib,bin,test}` for code; `plans/` and `docs/` at repo root.

Source of truth, in order of precedence:
- `plans/interpreter.md` — **Milestone 11.5 shipped** (router route-table demo
  `test/programs/router/service.di`; graceful-shutdown approximation
  `programs/router/graceful.di`). **Stage 12 — Scopes** (`@ Request`, ~line 1175)
  is next.
- `docs/lang/syntax.md`, `docs/lang/design.md`, `docs/lang/decisions.md`
  (decisions run through **DEC-022**).

## What shipped this round (summary)

- **Value-method dispatch on `VImpl` (DEC-020)** — closed the Stage-11 gap where
  user-struct/host-impl methods were reachable *only* via capability dispatch.
  `value_method_dispatch` now has a `VImpl` arm resolving against `iv.methods`;
  `DUser`/`cap_call` share helper `call_impl_method`.
  - **Caller-caps, deliberately.** Value-dispatched user methods run with the
    *caller's* caps (`ctx.caps`), not a captured `cap_env`, because a plain
    `let p = Point{…}` value was never wired through `provide`. Pinned by
    `vm_method_calls_cap.di`.
  - **Rust method/field rule.** `s.f(args)` is always an impl method; a field
    holding a function is called `(s.f)(args)`. Same-name field+method allowed.
    Missing-method error hints the `(x.f)(...)` form when a field of that name exists.
  - `(expr)(args)` general call form now parses (`atom`/`head_atom`) and runs —
    this unblocked `(r.handler)(req)` for the router.
- **Short-circuit `&&`/`||` (DEC-021)** — dedicated `And`/`Or` AST nodes. `||`
  lexes as one `BARBAR` (shared with zero-arg lambda `||body`); spaced `| |body`
  is two `PIPE`s. Precedence loosest→tightest: `BARBAR`, `AMPAMP`, `QMARK_QMARK`,
  comparisons, `+`/`-`, `*`/`/`.
- **Array type `[T]` in type position** — `type_name` gained `LBRACKET type_name
  RBRACKET` (erased at runtime). No DEC (implements already-documented §Arrays).
- **Inherent impls (DEC-022)** — bare `impl Type { fn … }` (no `for`, no
  interface) declares a type's own methods, reached by receiver via value
  dispatch. Removed the old "marker capability" hack (`Router` is now `impl
  Router { … }`). `caps=[]` is inert at runtime. Pinned by `vm_inherent_impl.di`.

## Still-open design question: `HttpServer`-as-value (now UNBLOCKED)

The precondition ("value-method dispatch on `VImpl` exists") is now met, so
`server.serve()` / `listener.accept()` on a value has a code path.
`programs/router/graceful.di` is a first approximation of design §4.8 (a `Router`
value with inherent-impl builder/dispatch + `defer` teardown, `--max-requests`
standing in for shutdown) — graceful *in spirit* only: no signals, no concurrency,
nothing to drain. Real graceful shutdown also needs Stage 15 (concurrency /
in-flight `Group`) and Stage 16 (`with_timeout` / cancellation). Substance, still
un-DEC'd:
- `HttpClient` is a clean capability (ambient authority, short effects) — keep.
- `HttpServer` fits worse (`serve` is long-lived, blocking, stateful). Principled
  alternative: a `Net` *authority* capability (`listen(port) -> Listener`) with
  `Listener`/server/`Router` as structs + impl. The router demo is already value-shaped.
- Eio guts stay a host impl either way; capability-vs-value only changes the
  interface. **Write a DEC when decided.**

## Carry-forward facts (still load-bearing)

- **Comments are `//` only** (no `(* *)`). **No `;` statement separator** —
  newline/adjacency-separated blocks.
- **`Logger` is not in the prelude** — only HTTP caps are. A service calling
  `Logger.info` must declare `capability Logger { fn info(msg: Str) }` itself.
  `StdoutLogger` is a host impl (always registered), but a host impl still needs
  its capability *declared* for `MethodCall` to route to cap dispatch.
- **Bare construction, DEC-009** — `Foo @ Process`, not `Foo()`.
  `interpreter.md` examples using `Foo()`, `catch _ { … }`, or `;` are
  aspirational; re-derive every program from the grammar and run it before pinning output.
- **`requires` precedes `raises`** in fn/cap signatures.
- **No module cycle:** `eval.ml` opens only `Ast` and `Value`, so `host_builtin.ml`
  calls `Eval.call_value`/`Eval.call_impl_method` and raises `Eval.Dilang_error` freely.
- **`impl_decl.caps`/`priv_requires` are never read at runtime** — only `for_ty`
  (indexes `impls_by_ty` in `driver.ml`) and `methods` (collected by
  `methods_for_ty`, which rejects duplicate names *across all impl blocks for a
  type*, inherent + `for`). Methods from inherent and `impl Cap for Type` blocks
  merge onto the same struct constructor. A future row-checker is where caps start mattering.
- **Prefix-route catch-all gotcha.** Router demos match `path.starts_with(prefix)`,
  so `prefix:"/"` catches *every* path. `router_graceful`'s 404 case uses an
  unbound `POST /missing`, not a GET. Demos keep first-match-wins (no
  longest-prefix/exact-match precedence).
- **Fork-based HTTP fixture sharp edges** (`run_test.ml`): child runs
  `Driver.run_file ~max_requests`, stdout dup2'd to a pipe, exits via `Unix._exit`;
  parent retries the **TCP connect** to wait for the listener; `waitpid` must
  **retry on `EINTR`**; budget `max_requests` to exactly the number of requests
  sent. Reusable driver `with_server ~prog` (`with_http_server ~service` wraps it);
  `http_get_raw`/`http_post_raw` send one request each. Request bodies read only
  when `Content-Length` present (GET-deadlock fix); responses read-to-EOF.
- **Manual router smoke:** `dune exec dilang -- run test/programs/router/service.di
  --max-requests 4` (background), then `curl localhost:18080/health`→`ok`,
  `curl -XPOST -d hi localhost:18080/echo`→`hi`, `curl localhost:18080/nope`→`no
  route`; exits clean after 4. Port is **18080**.
- **`trait` is still unimplemented.** Only `capability` exists as an interface
  decl (no `trait` keyword/parser/AST, despite syntax §3 / DEC-008). Value types
  use inherent impls (DEC-022); value-method dispatch (DEC-020) is the runtime
  mechanism a real `trait` would reuse.
- **DEC entries are cheap; keep writing them.**

## Out of scope (per `plans/interpreter.md`)

Per-request scoping (`@ Request`) — Stage 12. DB pool + `Lifecycle` — Stage 13.
Concurrent request handling (`EioHttpServer`) — Stage 15. Per-request timeouts —
Stage 16. Streaming/chunked/SSE — Stage 17. HTTPS/HTTP2/websockets — not on
roadmap. Header ergonomics deferred until a tuple/map value exists (DEC-019).
Row-polymorphic generics on function types deferred to the type-checker phase.

## Addendum (standing) — parser conflict budget

Committed parser sits at **14** conflict states (`lib/parser.conflicts`). All
shift/reduce, all resolved by desired default-shift. Three families: (1)
general-call-form `atom . LPAREN` / `dot_tail` empty-vs-`LPAREN` (overlaps bare
`IDENT LPAREN`, `expr→atom` statements, break/raise payloads); (2) `||`-operator
vs zero-arg-lambda-statement; (3) `BARBAR`/`AMPAMP` joining the break-payload and
lambda-body-absorbs-trailing-operator families (the operator-precedence state
shows the full `STAR…BARBAR…AMPAMP` token set). State numbers shift across
regens — consult `lib/parser.conflicts`, don't memorise IDs. Treat **14** as
baseline and `diff` on every parser change — if it moved, you touched the grammar.
