# Decision log

Stable IDs (`DEC-NNN`) for citation. Each entry: decision, rejected alternatives (one-liner each), cite. Append new entries; never renumber.

Scope: language design only — syntax, semantics, goals. Documentation, tooling, and project-organization choices live elsewhere.

Use this format:

```
## DEC-NNN — Title
Status: Active | Deferred | Superseded by DEC-XXX · Cites: design §X.Y
Decision sentence.
- Rejected: alt — reason
```

-----

## DEC-001 — Single `IO` capability (Zig-style)
Status: Active, split deferred · Cites: design §3.3, §5.2
Model the runtime as one `IO` capability. v4's twelve-capability split is deferred.
- Rejected: keep all twelve — dominates docs; obscures core ideas

## DEC-002 — Wiring composition via spread entries
Status: Active · Supersedes: v4's `++` / old `using` directive · Cites: design §3.5, syntax §7, RFC-001
`with [...a(), ...b(), Cap <- expr] @ 'Scope { ... }`. Lexical order; later wins.
- Rejected: `++` operators — operator soup; multiple syntaxes for one concept
- Rejected: unmarked unified `with [a(), b(), Cap <- ...]` — no per-entry signal
- Rejected: `using` as block-level marker — mixing bindings + Wirings needs special-casing

## DEC-003 — Compile-time Wiring check via structural tracing
Status: Active · Cites: design §3.5.4
`Wiring` is opaque at source level; compiler traces function bodies to compute provides/requires. Constraint: binding *sets* must be static; only constructor args may vary.
- Rejected: row-typed `Wiring<provides: {...}, requires: {...}>` — long boundary signatures
- Rejected: no static check — defeats the language's premise

## DEC-004 — Scoped `with` defaults and explicit mixed-scope bindings
Status: Active · Cites: design §2.8.3, syntax §7, RFC-001
`with [...] @ 'Scope { ... }` gives direct bindings in the entry list a default scope. If a `with` has no default scope, each direct binding must specify `@ 'Scope`.
- Rejected: default to `@ 'Process` — hides scope at binding site

## DEC-005 — No `Result<T, E>`; errors flow through `raises`
Status: Active (carried from v3) · Cites: design §2.5
- Rejected: `Result<T, E>` only — composes poorly with effect rows
- Rejected: both — two error paths is one too many

## DEC-006 — No `?` / `from` for error propagation
Status: Active (carried from v3) · Cites: design §2.5.3
Verbose re-tagging is intentional; keeps domain transitions visible.
- Rejected: `?` operator — hides boundaries

## DEC-007 — No function coloring; runtime via capability
Status: Active (carried from v3) · Cites: design §2.3
- Rejected: colored async — splits the stdlib; the central problem to avoid

## DEC-008 — Capabilities and traits as separate mechanisms
Status: Active (carried from v3) · Cites: design §2.7
- Rejected: unified — conflates dependency resolution with value shape

## DEC-009 — Struct literals use braces; calls use parens
Status: Active · Cites: design §2.9, syntax §1.1, §4.1, §7.2
Struct construction is `Foo { field: value }` (or `Foo` with no braces for fieldless structs). Function calls — including those with named args — are `foo(arg: value)`. The two forms are syntactically distinct at parse time.
- Rejected: unified `Foo(field: value)` for both — shape carries no semantic signal; reviewer must resolve the name to know whether the line allocates data or runs effects. Optimizing for review (most code will be agent-written) means the syntactic split earns its keep.
- Rejected: ban named args on functions — readability at call sites is too valuable to give up; reviewers benefit even more than writers from `connect(host: "...", port: 5432)` over positional.
- Rejected: require `Foo {}` even on empty structs — needless noise. Bare `Foo` constructs a fieldless struct, matching Rust's unit-struct ergonomics.

Implication: named args inside `(...)` always mean a function parameter; named entries inside `{...}` always mean a struct field. Renaming a struct into a fn (or vice versa) with the same name surfaces as a parse-level shape mismatch at call sites, not a silent semantic flip.

## DEC-010 — Function calls: named-args design (Deferred)
Status: Deferred · Cites: design §2.10
A previous version of this decision required every argument after the first to be named at the call site. Reverted after implementation surfaced design ambiguities (mixed positional/named ordering rules, interaction with variadic builtins, param-name renames as silent ABI breaks, scope on capability methods vs user fns). For now: **function and capability-method calls are fully positional.** Struct literals remain named (DEC-009) — that decision stands.

Revisit when the typechecker lands; getting the rule right benefits from having type info to surface mismatches with good error messages.

- Currently active position: fully positional calls. Reviewer-readability is left to writers using local variable names well, until the right named-args shape is figured out.

## DEC-011 — Defer / error interaction (Deferred)
Status: Deferred (v0 interpreter behavior noted) · Cites: syntax §14, design §2.5, §2.10
Two related open questions about how `defer` interacts with `raises`. Park both until `raises` is statically enforced; the answers want type information.

1. **What if a defer body itself raises?** Prior art splits:
   - Zig / Swift: ban at the type level — defer bodies must be unfailable; failing variants (Zig's `errdefer`) replace the in-flight error explicitly.
   - Go: latest panic wins; earlier ones are lost.
   - Interpreter v0 (Stage 6): swallow silently; subsequent defers still run; inner raise does not propagate. Documented in `eval.ml`'s `run_defers`. Chosen to avoid masking the original raise *and* to keep cleanup paths from dropping silently mid-list — but it does drop the inner error.
   Likely landing: Zig's stance. Once `raises` rows are checked, require defer bodies to have an empty `raises` row; lift the v0 swallow to a compile error.
2. **Should `errdefer` exist?** A defer that fires only on error-exit paths, not on normal return. Useful for "undo this allocation if we're bailing out." Easy to slot in once the activation distinguishes exit paths at the type level. Adds one keyword; symmetric with `defer` for the success path. Open whether to also add `successdefer` (D's `scope(success)`) or stop at the two-way split.

- Rejected for v0 (1): propagate inner raise — masks original raise; reviewer can't tell which fired
- Rejected for v0 (1): "last raise wins" — confusing; doesn't compose with multiple defers
- Rejected (preemptively, for the future shape): runtime `recover()` à la Go — §2.10 ("no exception swallowing") is a hard line

## DEC-012 — `defer` is block-scoped
Status: Active · Cites: syntax §14, design §2.5, §2.10
A deferred expression runs at the end of the smallest enclosing `{ ... }`, on every exit path from that block (fall-through, `return`, `break`, `continue`, raised error, cancellation, panic). Each `{ ... }` in the surface syntax is its own defer scope — fn body, `if`/`else` branch, `loop`/`while` body, `try`/`catch` body, `with` body, bare block expression. Defers within a block fire LIFO. The deferred expression is evaluated at fire time, not at registration (so reads of mutable state see scope-exit values).

Matches Zig / Swift / D `scope(exit)`. Diverges from Go (function-scoped + arguments captured at registration).

- Rejected: function-scoped (Go-style) — turns the obvious `for { defer release(x) }` into a leak that holds N resources until function exit. Forces awkward refactors (extract the loop body into a helper fn). Fails the "deterministic cleanup next to its setup" goal from §2.5 because cleanup runs far from the setup site.
- Rejected: scope-on-keyword-only (`defer` block-scoped, but a separate `func_defer` for function-scoped) — two cleanup keywords doubles the surface area. Function-scoped cleanup is expressible by registering the defer at the top of the fn body, where the scope *is* the function.
- Rejected: per-`try`-only scoping — special-cases one construct; reviewer can't predict scope from the keyword alone.

Interpreter note (Stage 6): implemented by wrapping every block built from `{` ... `}` with `Fun.protect`, with a fresh per-scope `defers` ref swapped onto `ctx`. Activation boundaries (`call_fn`, `DUser`) no longer own defer state — the fn body's own `{ ... }` is the activation's defer scope.

## DEC-013 — `loop` is an expression; `while`/`for` are statements
Status: Active · Cites: syntax §11, design §2.10
`loop { ... }` evaluates to the value carried by `break v` (or `VUnit` if `break;` without value). A `loop` with no reachable `break` has type `Never`. `while cond { ... }` and `for x in xs { ... }` always evaluate to `VUnit` — they may not execute the body at all, so there is no well-defined value to yield.

Matches Rust. The asymmetry is the right call: `loop` is the construct you reach for when you want to compute a result that requires iteration with conditional exit (retry loops, polling), and `break v` is the clean idiom for "here's the answer." `while`/`for` are predicate-driven and the natural return is "done."

- Rejected: all loops statement-shaped (the original Stage-7 plan) — forces an out-of-band mutable binding for "the value the loop computed," which is exactly the pattern `loop`/`break v` exists to remove.
- Rejected: all loops expression-shaped — `while`'s value is undefined when the body never runs; no good answer that doesn't introduce `Option` at every use site.
- Rejected: `break v` allowed in `while`/`for` — only useful when the body runs at least once, and the type checker can't prove that without flow analysis we don't want to require.

Interpreter (Stage 7): `Break_exn` carries an optional value (`Break_exn of value`; bare `break` → `Break_exn VUnit`). The `Loop` arm catches and returns the carried value; `While` / `For` arms catch and discard, returning `VUnit`.

## DEC-014 — Field mutation requires `mut` on the binding (Deferred)
Status: Deferred (v0 interpreter behavior noted) · Cites: design §2.1, §2.10, syntax §1
The eventual rule: `recv.field = rhs` is legal only when `recv` was bound `let mut` (or the field is reached through a chain whose root binding is `mut`). Matches Rust: `let s = Foo{...}; s.field = …` is a compile error; `let mut s = Foo{...}; s.field = …` is fine. Same review-time visibility argument as DEC-002.10's "mutation is visible at the binding site": if `s` is `let` (no `mut`), nothing that follows can mutate the value reachable through it.

Interpreter v0 (Stage 7): **not enforced.** `AssignField` walks straight through the field-as-ref the struct constructor produced (Stage 4) without consulting the binding's `mut` flag, so `let t = Tally{count: 0}; t.count = 1` runs successfully. Documented at the `AssignField` arm in `eval.ml` and at the call sites in `test/stages/07i_mutate_field.di` / `07j_mutate_self_field.di`.

Likely landing: enforce at the parser/typechecker boundary once we have a flow-sensitive way to trace the root binding of an `AssignField`'s receiver chain. Until then, the interpreter accepts more programs than the language definition will eventually allow — programs that rely on this leniency will need a `mut` added to compile under the stricter rule.

- Rejected for v0: enforce in the interpreter now — needs receiver-root tracing through arbitrary expr chains (`a.b.c.d = …`), which is doable but easier with the typechecker's plumbing in place.
- Rejected: drop the rule (allow field mutation on any binding) — contradicts §2.10's "optimize for review: mutation is visible at the binding site." A reader who sees `let s = …` should be entitled to assume nothing downstream mutates state reachable through `s`.

## DEC-015 — Indexed/method mutation requires `mut` on the receiver root (Deferred)
Status: Deferred (v0 interpreter behavior noted) · Cites: design §2.1, §2.10, syntax §1
Companion to DEC-014. The eventual rule: `xs[i] = rhs` and mutating value-method calls (`xs.push(v)`) are legal only when `xs` was bound `let mut` (or the chain's root binding is `mut`). A reader who sees `let xs = …` should be entitled to assume nothing downstream grows or rewrites the array reachable through `xs` — same review-time argument as DEC-014.

Interpreter v0 (Stage 8): **not enforced.** `AssignIndex` writes directly through the `VArray` ref produced by `ArrayLit`, and `VArray.push` mutates the underlying ref regardless of the receiver's `mut` flag. So `let xs = [1, 2, 3]; xs[0] = 99` and `let xs = []; xs.push(1)` both run successfully. Documented at the `AssignIndex` arm and the `VArray, "push"` arm in `eval.ml`, and at the call sites in `test/stages/08e_index_assign.di` / `test/stages/08h_empty_push.di`.

Likely landing: same as DEC-014 — enforce at the parser/typechecker boundary once we have flow-sensitive receiver-root tracing. Programs that rely on this leniency will need a `mut` added.

- Rejected for v0: enforce in the interpreter now — see DEC-014; same tracing problem.
- Rejected: drop the rule — same §2.10 argument as DEC-014.

## DEC-016 — `s.split("")` panics rather than fanning out to characters
Status: Active · Cites: interpreter.md §"Stage 9 — Strings"
Splitting a string on the empty separator has no single obvious meaning — `"abc".split("")` could plausibly yield `["a", "b", "c"]`, `["", "a", "b", "c", ""]`, or `["abc"]` depending on the convention. Rather than silently pick one, Stage 9 rejects it at runtime with the specific panic `split: separator must be non-empty`. A clear failure beats a silent surprise, and char-level operations are explicitly deferred in v0 (no `.chars()`, no `s[i]`), so there is no established "characters of a string" surface for empty-split to defer to.

Interpreter (Stage 9): the empty-separator guard precedes the general `VStr sep` arm in `value_method_dispatch` (`eval.ml`), so `s.split("")` produces exactly that message; `String_util.split_on_substring` may therefore assume a non-empty separator. All other splits — including `"".split(sep)` → `[""]` and separators at the boundaries → empty pieces — go through normally. Pinned by `test/run_test.ml`'s `errors/split_empty_sep` case.

Likely landing: a future typechecker can lift this from a runtime panic to a static non-empty-separator precondition. Until then the interpreter is the only enforcement point.

- Rejected: fan out to one-element-per-character — picks one of several conventions arbitrarily and contradicts the v0 decision to defer all char-level string operations.
- Rejected: return the whole string as a single element (`["abc"]`) — equally arbitrary, and silently makes a likely-buggy call look successful.

## DEC-017 — Function values display as `<closure>` / `<fn NAME>`
Status: Active · Cites: syntax §1.2–1.3
A function value passed to `print()` displays as a fixed marker rather than panicking: `VClosure` → `<closure>`, `VFn f` → `<fn NAME>` (e.g. `<fn foo>`).

Stage 10 introduced first-class function values (lambdas and bare top-level fn names used as values). `print(f)` must produce *something*; panicking on a function value would lose a cheap debugging affordance. The marker is a display convention only — it implies no identity or equality semantics, and deliberately leaks none of the captured environment or capability stack (that would be noisy and a format we'd regret pinning).

Interpreter (Stage 10): the two cases live in `Value.to_display` (`value.ml`); pinned by `test/stages/10_fn_value_display.di` (`<closure>` then `<fn foo>`).

- Rejected: panic on a function value — loses a cheap debugging affordance for no benefit.
- Rejected: include the captured env/caps in the display — noisy, and a format we'd be stuck supporting.

## DEC-018 — Stdlib declarations injected via a parsed `.di` prelude (Stopgap)
Status: Active (explicitly temporary) · Cites: interpreter.md "Stage 11", design §3 (modules/stdlib, not yet specified)
The Stage 11 capability *interfaces* (`HttpServer`, `HttpClient`), data *types* (`Request`, `Response` structs), and the `HttpError` enum are declared in ordinary dilang source held in `lib/prelude.ml` and **prepended to the user program** before `build_tables` (`driver.ml run_program`). Only the host *impls* (`BlockingHttpServer` / `BlockingHttpClient`) stay as OCaml constructors. The prelude adds **no language surface**: it is parsed by the same `parse_string` and lowered through the same `build_tables` as user code, so `HttpServer`/`HttpClient` land in `cap_decls`/`ext_of`, `Request`/`Response` become `user_constructors`, and `HttpError` flows through the ordinary user-enum loop. Nothing in it is privileged (it defines none of the reserved names — `HttpError` ≠ `Option`).

This is an **explicit stopgap** until a real module system + standard library exist; at that point these declarations move into an importable stdlib module and the prelude file disappears. Documented in `lib/prelude.ml`'s header.

- Rejected: inject the types as OCaml `Ast` values directly — duplicates `build_tables` logic, risks a parallel code path drifting from the parser, and reads less like "this is just dilang."
- Rejected: hard-code `Request`/`Response`/`HttpError` as new `VVariant`/native values — bakes a not-yet-designed stdlib shape into the interpreter core; harder to revise than text.
- Rejected: require users to declare the HTTP types themselves — every HTTP program would repeat boilerplate the language is supposed to provide.

## DEC-019 — HTTP v0 representation: no headers; no auto-`BadStatus`
Status: Active · Cites: interpreter.md "Stage 11"
Stage 11's HTTP types are `Request { method, path, body }` and `Response { status, body }` — **no headers**. dilang has no tuple/`VTuple` (or map) value, so there is no ergonomic way to carry a `(name, value)` header collection yet; headers wait for a richer value model. Additionally, the client does **not** auto-raise `HttpError.BadStatus` on responses with status ≥ 400 in v0 — every response is returned as a `Response` regardless of status (the `BadStatus(code)` variant exists for callers and future use). `HttpError` is raised only for transport-level failures: `InvalidUrl` (unparseable `http://host[:port]/path`) and `ConnectionFailed(reason)` (resolve/connect failure).

- Rejected: encode headers as parallel `Str` arrays or a `key=value` blob — picks an arbitrary shape we'd be stuck supporting; better to wait for tuples/maps.
- Rejected: auto-raise `BadStatus` on ≥400 — conflates "the request completed and the server answered" with "the transport failed"; callers that want status-based control flow can branch on `resp.status`.

## DEC-020 — Value-method dispatch on `VImpl`; method/field disambiguation follows Rust
Status: Active · Cites: syntax §4 ("Calling methods vs. field-held closures"), §Arrays ("Method dispatch")
`recv.name(args)` on a user struct / host impl value resolves `name` against the impl's methods (`iv.methods`). User methods run with `self` bound to the receiver and the **caller's** caps (`ctx.caps`) — deliberately *unlike* capability dispatch (`cap_call`), which uses the impl's captured `cap_env`, because a plain struct value was never wired through `with`. Method/field naming follows Rust: `s.f(args)` is **always** an impl-block method; a field of function type is invoked with the parenthesised call form `(s.f)(args)` (a `FieldGet` yielding the function value, then a general call). The two syntaxes are distinct, so there is no runtime precedence to resolve and a same-name field+method is permitted (separate namespaces).

Before this, `value_method_dispatch` handled only `[T]` and `Str`; any `VImpl` fell through to *"method … not supported on this value."* — user-struct/impl methods were reachable only through capability dispatch. This unblocks Milestone 11.5's router (`(r.handler)(req)`) and the eventual reshaping of `HttpServer` from a capability into a value.

Interpreter: a `VImpl` arm in `value_method_dispatch` (`eval.ml`) — `DUser m` calls the shared `call_impl_method ctx iv m … ~caps:ctx.caps ~bind_self:true`; `DHost f` calls the host fn. A missing method whose name matches a field errors with *"field f on T is not a method; call it as (x.f)(...)"*; otherwise *"no method f on T"*. The general call form `(expr)(args)` is a new `atom`/`head_atom` production; the parser default-shifts the `IDENT . LPAREN` and `x . f . LPAREN` overlaps so `print(x)` / `Some(1)` keep their special rules and `x.f()` stays a method call. Pinned by `test/stages/vm_*.di` and `test/run_test.ml`'s `errors/field_not_method` + `no_method_on_struct`.

- Rejected: make `s.f(args)` fall back to calling a field-held function when no method `f` exists — reintroduces the runtime precedence the Rust rule removes; a rename that turns a method into a field (or vice versa) would silently keep type-checking.
- Rejected: dispatch user value-methods with the impl's captured `cap_env` (mirroring `cap_call`) — a plain `let p = Point{…}` value was never wired through `with`, so its `cap_env` is empty; using it would make a method that calls a capability fail even when the caller has that capability in scope.

## DEC-021 — Short-circuit `&&` / `||`
Status: Active · Cites: syntax §1 ("Operators")
Logical `&&` and `||` evaluate the right operand only when the left does not decide the result; both operands must be `Bool`. Precedence: looser than `??`/comparisons, with `&&` binding tighter than `||` (`%left BARBAR` then `%left AMPAMP`). They are dedicated AST nodes (`And`/`Or`), **not** `bin_op` variants, because `eval_binop` takes both operands already evaluated — short-circuiting requires deciding whether to evaluate the right operand from the left's value.

`||` lexes as a single `BARBAR` token, shared between the operator and the zero-arg lambda `||body` (parsed by a `BARBAR`-prefixed lambda rule); the spaced `| |body` still lexes as two `PIPE`s (empty param list), so both spellings of the zero-arg lambda survive.

Interpreter: `And`/`Or` arms in `eval.ml` (before the eager `BinOp` arm); non-`Bool` operands raise *"&& operands not Bool"* / *"|| operands not Bool"*. Pinned by `test/stages/vm_short_circuit.di` (side-effect ordering proves the RHS is skipped) and `errors/and_non_bool`.

- Rejected: desugar to nested `if` in the parser — obscures the operator at the AST level and complicates the router's match condition; dedicated nodes are clearer.
- Rejected: add `And`/`Or` to `bin_op` and special-case them in `eval_binop` — `eval_binop` receives pre-evaluated operands, so it structurally cannot short-circuit; the special case would have to live in the `BinOp` eval arm anyway.
- Rejected: lex `||` as two `PIPE`s (no `BARBAR`) — then the or-operator and the spaced zero-arg lambda are indistinguishable to the parser.

## DEC-022 — Inherent impls (`impl Type { ... }`)
Status: Active · Cites: syntax §4.2, design §2.7 (capabilities vs traits, DEC-008)
A type's own methods are declared with a bare `impl Type { fn ... }` — no capability or trait interface, no `for`. They are reached by receiver through value-method dispatch (DEC-020), never through `with`. This is the Rust inherent-impl form, and it is the right shape for value types whose methods are intrinsic (a `Router`'s `dispatch`, a `Stack`'s `push`) rather than a named interface the type satisfies.

Motivation: before this, every `impl` had to name a capability (`impl Cap for Type`), forcing value types to either declare a "marker capability" — semantically wrong, since the methods are receiver-resolved, not `with`-resolved (DEC-008's trait side, which is not yet implemented) — or lean on an undeclared cap name (works, but unvalidated). An inherent impl says exactly what is meant. It is **orthogonal to traits**: when `trait` lands it will be the named-interface-resolved-by-receiver form; inherent impls are the no-interface form. Both compose with `impl Cap for Type` on the same type (methods merge; duplicate names across blocks are rejected by `methods_for_ty`).

Interpreter: a second `decl` production `IMPL IDENT LBRACE ... RBRACE` (`parser.mly`) producing `DImpl { for_ty; caps = []; … }`. `caps`/`priv_requires` are never read at runtime — only `for_ty` (to index `impls_by_ty`) and `methods` — so an empty caps list needs no further plumbing. The parser disambiguates one token after `IMPL IDENT` (`LBRACE` → inherent; `FOR`/`PLUS` → `impl X for Y`); LR(1)-decidable, **zero** new conflicts. Pinned by `test/stages/vm_inherent_impl.di` and the `router_graceful` demo/test.

- Rejected: require a marker capability on value types — implies `with`-resolution that never happens; misleads the reader about how the methods are found.
- Rejected: allow `impl Cap for Type` with `Cap` undeclared as the idiom — works only by absence of validation; a future "impl names a known interface" check would break it, and it still reads as if `Cap` means something.
- Rejected: wait for `trait` and model these as traits — inherent (no-interface) methods and trait (named-interface) methods are distinct concepts; Rust keeps both, and the no-interface case is the common one for a program's own value types.
