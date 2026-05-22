# Capability-Native Language: Design

This is the design document. It states what the language is for, the principles that guide its design, and the conceptual model. It deliberately contains very little code — syntax lives in [syntax.md](./syntax.md) and concrete programs live under [examples/](./examples/).

Paragraphs are numbered (legal-style: §section.paragraph) so they can be cited unambiguously in discussions. When something is referenced as "see §3.2.4" it points to a specific paragraph in this document.

This supersedes [archive/capability-language-design-v4.md](./archive/capability-language-design-v4.md). The archived version remains as historical reference; it is not authoritative.

-----

## 1. Motivation

### 1.1 The problem

1.1.1 Dependency injection in mainstream languages is bolted on. Annotation+container frameworks (Spring, Dagger, .NET DI) resolve dependencies at runtime, errors surface late, and the DI machinery is alien to the language proper. Implicits or context parameters (Scala 3, Kotlin 2.2) move resolution to compile time but inherit limitations from being retrofitted into a non-DI language: composition is awkward, lifetimes are unclear, and the rules around scoping vary by feature. Algebraic effects (Koka, Effekt) are principled and powerful, but the learning curve excludes most working programmers.

1.1.2 Concurrency in mainstream languages is similarly compromised. Colored async (Rust, JS, Python, C#) infects function signatures, splits the standard library into sync and async halves, and forces every library author to pick a side. Runtime-managed fibers (Go, BEAM, JVM virtual threads) avoid coloring but typically bundle scheduling, I/O, time, and process concerns into one runtime interface — meaning a function that only writes to a socket transitively pulls in the entire runtime surface, and targets that cannot provide part of that surface (browsers, embedded) must lie about what they have.

1.1.3 These two problems are usually treated separately. They are the same problem. Both are about *what a function depends on*: in the DI case, services and configuration; in the concurrency case, the runtime itself. A language that takes dependencies seriously at the type level can address both.

### 1.2 The thesis

1.2.1 Dependency injection should be a first-class language feature, checked at compile time. Dependencies — both user services and the runtime itself — are tracked through the type system as **capability rows** that flow through function signatures. They are satisfied by lexically-scoped `provide` blocks that bind capability names to implementations.

1.2.2 User code should read as synchronous. There is no `async`/`await`, no two parallel standard libraries. Whether a call blocks an OS thread, suspends a fiber, runs on an event loop, or executes immediately is decided at `main` by the choice of runtime implementation, not at every function signature.

1.2.3 The runtime is exposed as a capability. The same `provide` mechanism that wires `Database` and `Logger` also wires the scheduler, the clock, the network, and the filesystem. Tests use the same wiring mechanism as production.

-----

## 2. Guiding principles

### 2.1 Dependencies are visible in signatures

2.1.1 If a function uses a capability, its signature says so. There is no ambient state, no global service locator, no thread-local container. A reader looking at a function signature can enumerate exactly what it needs to run.

2.1.2 The compiler enforces this exactly: a `pub` function that declares it needs `{Database, Logger}` and uses `Clock` in its body is a compile error, not a warning. Over-declaration (listing a capability the body never touches) is equally an error. The declared row is the truth.

2.1.3 The cost of this principle is signature length. A controller that pulls together several services may list many capabilities in its `requires` row. This is intentional. The discomfort is the signal that the function is doing too much; the fix is decomposition, not hiding the dependencies.

### 2.2 Wiring is lexical and explicit

2.2.1 Capabilities enter scope through `provide` blocks. A `provide` block is a lexical region in which named capabilities are bound to specific implementations. Outside that region, those bindings do not exist.

2.2.2 There is no global registry, no startup-time scan, no annotation magic. The path from the use site to the binding site is the call stack — you can trace it by reading the code.

2.2.3 Wiring is itself a value. A `provide { ... }` expression without a body produces a `Wiring` value that can be stored, returned, and passed around. Composition happens inside another `provide` block via the `using` directive (see §3.5). This is how production and test wiring share infrastructure: define a base wiring as a value, splat it into another `provide` and layer overrides on top.

### 2.3 No function coloring

2.3.1 Functions do not declare `async`. Awaiting is not a syntactic operation. Calling a function that may suspend looks exactly like calling a function that does not.

2.3.2 This is made possible by routing every operation that might suspend through a capability. A function that calls `IO.read(socket, buf)` declares `requires {IO}` in its row. The implementation of `IO` chosen at `main` decides what "read" means: it might park a fiber, it might block an OS thread, it might post a callback. The caller's code is the same.

2.3.3 The same mechanism makes tests deterministic. A test runtime can implement `IO` to run tasks sequentially, advance simulated time without sleeping, and capture stdout. User code does not change.

### 2.4 The runtime is a deployment choice

2.4.1 The set of capabilities provided at `main` defines what the program can do. A program built to run on a server provides a full IO implementation. A program built for the browser or an embedded device provides a restricted implementation. The same business logic runs on both, as long as it does not require capabilities the target cannot provide.

2.4.2 If business logic transitively requires a capability the target does not bind, this is a compile error at the `provide` site — not a runtime crash, not a silent stub. Targets are honest about what they support.

### 2.5 Errors are part of the signature

2.5.1 Every function declares the errors it can raise in a `raises` row, parallel to `requires`. Errors propagate via `raise` and are caught by `try ... catch`. There is no `Result<T, E>` type and no `?` operator for error propagation.

2.5.2 The success path returns a value directly; the error path goes through the rows. This is one fewer concept than the value-of-result-of-value approach and keeps the effect rows as the single source of truth about what a function does to the outside world.

2.5.3 Re-tagging errors at domain boundaries (catching a `DbError` and raising a domain-specific `RepoFailure`) is explicit. There is no implicit conversion. The verbosity is the point: error-domain transitions should be visible at the call site.

### 2.6 Lexical resource cleanup

2.6.1 Two cleanup mechanisms exist. `defer { ... }` blocks run on every exit from the enclosing function — normal return, raised error, cancellation, or panic. `Drop` is a trait implemented by values that need cleanup when they go out of scope.

2.6.2 Capabilities bound in `provide` blocks have a separate mechanism, `Lifecycle`, with `start()` and `shutdown(exit_reason)`. Lifecycle runs on entry to and exit from the `provide` block, in dependency order.

2.6.3 The boundary is: if the thing is bound in a `provide` block, use `Lifecycle`. If the thing is a value flowing through the program, use `Drop`. If you need cleanup at every exit path of a function regardless of value lifetime, use `defer`.

### 2.7 Two interface mechanisms: capabilities and traits

2.7.1 **Capabilities** model dependencies. They are resolved lexically through `provide` blocks. Methods are called as `Cap.method(args)` — the capability name itself names the binding. Capabilities appear in `requires` rows.

2.7.2 **Traits** model the shape of values. They are resolved by the receiver value. Methods are called as `value.method(args)`. Traits appear as constraints on generic parameters (`<T: Eq>`), not in `requires` rows.

2.7.3 The two share syntactic shape (`impl X for Type`) and both support composition via `extends`. They are distinguished by how they are declared and how they are resolved. The heuristic: if a function would say `requires {X}` to use `X`, declare `X` a capability. If a function would take `x: X` as a parameter, declare `X` a trait.

### 2.8 Scopes are explicit

2.8.1 A scope is a declared lifetime region. `Process` is the implicit root scope. Users may declare additional scopes (`scope Request`, `scope Transaction`).

2.8.2 Capabilities can be annotated with the scope they belong to (`capability RequestCtx @ Request`). The compiler rejects use of a scoped capability outside its declared scope.

2.8.3 Every binding in a `provide` block specifies its scope explicitly with `@ ScopeName`. There are no defaults. Scope visibility is a deliberate design choice at every binding site.

### 2.9 Construction and calls are syntactically distinct

2.9.1 Struct/impl literals use braces: `Foo { field: value }`. Function and method calls use parens: `foo(arg)`, `Cap.method(arg)`. The shape carries semantics — a reader can tell *pure data construction* from *invocation* without resolving the name.

2.9.2 Fieldless structs may be constructed with the bare name (`JsonLogger` ≡ `JsonLogger {}`), matching the unit-struct ergonomics that keep `provide` blocks readable.

2.9.3 Renaming a struct into a function (or vice versa) with the same name produces a parse-level shape mismatch at every call site, not a silent semantic flip. The cost of two syntaxes buys this refactor safety. See DEC-009.

### 2.10 Optimize for review, not writing

2.10.1 The dominant cost of code is reading it — at review, after returning to it months later, when a new contributor lands. Most code today is being written by agents; most of the human time spent on a codebase is review. The language design treats writers as the secondary audience.

2.10.2 Concrete manifestations: `requires {...}` rows on signatures (§2.1), explicit `@ ScopeName` on every binding (§2.8.3), the absence of `?` for error propagation (§2.5.3), and the construction/call syntactic split (§2.9). In each case the writer types more so the reader thinks less. That trade is the right one when an LLM types most of the keystrokes.

2.10.3 Named arguments at call sites would be another natural manifestation of this principle but the design is non-trivial (DEC-010 deferred). Until then, the burden falls on writers to use descriptive local names so `deposit(account, amount, currency)` reads at least as `deposit(alice_account, transfer_amount, usd)`.

-----

## 3. Conceptual model

This section describes the language's concepts without code. Concrete syntax is in [syntax.md](./syntax.md); worked programs are in [examples/](./examples/).

### 3.1 Capabilities

3.1.1 A capability is a named interface that represents a dependency. Declaring a capability `Logger` with methods `info`, `warn`, `error` says "any code may demand a logger; any implementation of logging may be bound to that demand."

3.1.2 A capability is *demanded* by listing it in a function's `requires` row. A capability is *supplied* by an implementation (`impl Logger for JsonLogger`) bound inside a `provide` block. The compiler matches demand to supply by walking outward from the use site through enclosing `provide` blocks.

3.1.3 Capabilities can extend other capabilities (`capability WriteDb extends ReadDb`). An impl of `WriteDb` satisfies a requirement for `ReadDb`.

3.1.4 Implementations may have their own private requires row — capabilities they need internally that are *not* visible to callers. A `Postgres` impl of `Database` might internally need `IO` to drive its socket; callers of the `Database` capability see only `requires {Database}`, not `requires {Database, IO}`. This is what makes capability composition tractable: the surface a caller sees does not grow with the implementation's internal needs.

### 3.2 Effect rows

3.2.1 An effect row is a set, written `{A, B, C}`. Functions carry two effect rows in their signature: `requires` (capabilities the function needs in scope) and `raises` (errors the function can produce).

3.2.2 Rows compose with `+`. `{R + Database}` extends a row variable `R` with `Database`. `{R + S}` unions two row variables. This is how generic middleware works: a logging middleware can be written once and used over any underlying handler's row.

3.2.3 The compiler unifies rows on set equality. Order does not matter. Duplicates are not meaningful.

3.2.4 Rows on `pub` functions are declared explicitly and checked for exact match against the body. Rows on non-`pub` functions are inferred. The boundary is: anything that crosses an API surface gets explicit rows; internal refactors do not pay a notation cost.

### 3.3 The IO capability

3.3.1 The runtime — scheduling, sleep, networking, filesystem, standard streams, signals, process control, entropy, and synchronization primitives — is exposed as a single capability called `IO`. Code that performs runtime operations declares `requires {IO}`.

3.3.2 This follows Zig's approach: a single runtime interface, passed by capability rather than as an explicit parameter. Different implementations of `IO` produce different execution semantics (blocking threads, fibers, microtasks, sequential test execution) without changing user code.

3.3.3 In a later iteration we may split `IO` into finer-grained capabilities (`IO.Net`, `IO.Clock`, `IO.FileSystem`, etc.) so that code declares only the slice of the runtime it touches, and targets that cannot provide part of the runtime fail at compile time rather than at first call. For now, the single-capability model is preferred because it keeps examples readable. The splitting question is independent of the rest of the design and can be revisited without breaking other features.

3.3.4 Concurrency primitives — `Future<R, E>`, `Group<R, E>`, cancellation tokens — are stdlib value types whose methods require `{IO}`. Spawning a task, awaiting it, cancelling it, and combining tasks into groups all go through these types.

### 3.4 Cancellation

3.4.1 Cancellation is a first-class primitive. `IO.with_cancel(action)` runs `action` with a fresh cancellation token in scope. Tripping the token (typically from a sibling task, signal handler, or timer) causes any operation currently suspended under that scope, or any subsequent suspending operation, to raise a `Cancelled` error at its next suspension point.

3.4.2 Timeouts are derived from cancellation. `with_timeout(d, action)` is a stdlib helper that combines `with_cancel` with a timer task that trips the token after `d`. There is no special `with_timeout` primitive.

3.4.3 `defer` blocks run on every exit path including cancellation. This is what makes cancellation safe: cleanup is guaranteed regardless of how the function exits.

3.4.4 Critical sections that must not be interrupted mid-protocol can be wrapped in an `uncancellable { ... }` block. Cancellation requested during the block raises only after the block exits.

### 3.5 Wiring values

3.5.1 A `provide { bindings }` expression without a body is a value of type `Wiring`. It captures a set of bindings that have not yet entered any lexical scope.

3.5.2 Wirings compose by being splatted into another `provide` block via the `using` directive. Each entry inside a `provide` block is either a binding (`Cap = expr @ Scope`) or a `using` directive that splats one or more Wirings (`using w1, w2`). Entries combine in lexical order; later entries shadow earlier ones on conflict. There is no separate composition operator — composition is a `provide`-block construct, not a value-level one.

3.5.3 This is what makes test setup tractable. A base test Wiring binds the common infrastructure (test logger, fixed clock, in-memory database). Specific tests splat the base via `using` and add their overrides as later entries. There is no fixture inheritance, no parameterized container — just lexical composition.

3.5.4 The compiler statically tracks what each Wiring provides and what it still requires. This works because bindings inside a Wiring are syntactically restricted: the cap name, the impl type, and the scope are all compile-time-known per entry. Only the impl's *constructor arguments* may carry runtime data. A `Wiring`-returning function must therefore produce the same binding set on every call; only the values flowing into impl constructors may vary. The eventual `provide w in { body }` site then checks that `body.requires ⊆ w.provides` and that `w` has no unsatisfied private requires.

### 3.6 Scopes and Lifecycle

3.6.1 Every program runs inside an implicit `Process` scope. User-declared scopes (`scope Request`, `scope Transaction`) describe shorter-lived regions.

3.6.2 A capability annotated `@ ScopeName` may be bound only in a `provide` block targeting that scope. Re-entering the scope (the framework re-entering `provide @ Request` per request, for example) yields a fresh instance.

3.6.3 The `Lifecycle` trait — `start()` and `shutdown(exit_reason)` — runs on every entry to and exit from a `provide` block where the impl is bound. Startup order is the topological order of `requires` rows on `start` methods, with ties broken by lexical declaration order. Shutdown runs in reverse.

3.6.4 If a `start()` fails, the impls that started successfully are shut down in reverse order with an exit reason indicating the failure, and the original error propagates. The failing impl is not asked to shut down — it never finished starting.

3.6.5 Transactions fit naturally into this model. A `Transaction` scope with a `DbTx` capability that implements `Lifecycle` to issue `BEGIN` on start and `COMMIT`/`ROLLBACK` on shutdown gets atomic transactions with no special syntax.

-----

## 4. Compile-time guarantees

### 4.1 What the compiler rejects

4.1.1 Calling a capability method without that capability available in lexical scope (no enclosing `provide` block, or the binding is in a different scope from the call site).

4.1.2 A `pub` function whose declared rows do not match its body's inferred rows. Both under-declaration (used but not listed) and over-declaration (listed but not used) are errors.

4.1.3 Using a scoped capability outside its scope.

4.1.4 Raising an error variant not declared in the function's `raises` row, or letting an error escape a `try ... catch` without re-declaring it.

4.1.5 Constructing an impl whose private `requires` row is not satisfied at the `provide` site.

4.1.6 A cycle in `Lifecycle.start()` requirements.

4.1.7 Forward references inside a single `provide` block. Bindings can only see earlier bindings.

4.1.8 A `provide` binding without an explicit `@ ScopeName`.

4.1.9 Using a capability name as a generic constraint, or a trait name in a `requires` row.

4.1.10 Generic parameter use whose trait bounds are not satisfied.

### 4.2 What the compiler guarantees

4.2.1 If the program builds, every capability use has a binding reachable through lexical scope.

4.2.2 If the program builds, every error path is either handled or declared.

4.2.3 If the program builds, every `defer` block runs on every exit path including cancellation and panic.

4.2.4 If the program builds, every public function's signature accurately describes its dependencies and effects.

-----

## 5. Out of scope (for now)

This section lists real questions the design does not yet answer. None of them block the current iteration; each is recorded so it is not lost.

### 5.1 Module system

5.1.1 The `IO` naming is currently a single name without any module construct. There is no `module` keyword, no imports, no visibility rules across files. Convention suggests names like `db.ReadDb`, `observability.Logger` will appear; language support is deferred.

5.1.2 When modules arrive, the meaning of `pub` may extend or change. Currently `pub` is only a row-checking modifier, not a visibility modifier.

### 5.2 Splitting IO into finer capabilities

5.2.1 The single `IO` capability bundles unrelated runtime concerns. A pure logger that only writes to stdout transitively pulls in the scheduler, networking, and filesystem through the bundled interface. This is the same problem that motivated v4's twelve-capability split.

5.2.2 Splitting `IO` is deferred until the examples make the cost concrete. A likely split is `IO.Tasks`, `IO.Clock`, `IO.Sleep`, `IO.Net`, `IO.FileSystem`, `IO.Stdio`, `IO.Process`, `IO.Entropy`, `IO.Sync`, but the exact carving should be informed by real usage patterns.

### 5.3 First-class capability values

5.3.1 Functions currently return concrete impl types (`fn database_for(tid) -> Postgres`). This restricts patterns like multi-tenancy with different backend kinds per tenant.

5.3.2 Upgrade paths: a `Cap<X>` type for first-class capability values, or existential `impl Trait`-style returns. Both interact non-trivially with `extends` subtyping, scopes, and `Lifecycle`.

### 5.4 Variance, HKTs, associated types, GATs

5.4.1 All generic parameters are invariant. Higher-kinded types, associated types, and generalized associated types are not present. Each is a substantial design exercise.

### 5.5 Reference types and borrowing

5.5.1 There is no `&T` / `&mut T` system. Mutation is binding-level (`let mut x`). A full ownership/borrow system is deferred.

### 5.6 Signature length

5.6.1 Controllers that pull together many services produce long `requires` rows. This is by design — dependencies are visible — but the friction is real. A `bundle` construct was considered and rejected as undermining visibility. The question of whether any sugar helps without losing the property remains open.

### 5.7 Closure capability surface

5.7.1 Closures that escape their lexical context carry inferred rows. In non-trivial closures this can produce surprising couplings. The inference is preserved; tooling that visualizes a closure's row is the suggested mitigation, but no such tooling exists yet.

### 5.8 Per-scope-instance Lifecycle cost

5.8.1 Request and Transaction scopes can have many concurrent instances. `Lifecycle.start`/`shutdown` semantics are specified per-entry, but the runtime cost and concurrency story is not pinned down.

### 5.9 Module of error promotion ergonomics

5.9.1 Re-tagging errors at boundaries (`try X catch DbError(e) -> raise DbFailure(e)`) is verbose by design but accumulates noise. Library-level helpers may address it; no language sugar is planned.

### 5.10 Tooling

5.10.1 IDE support for visualizing capability flow, scope annotations, effect rows, and closure capability surfaces does not exist. This is critical for the language to be pleasant in practice.

-----

## 6. Note on history

6.1.1 This document is the current canonical design. Earlier versions explored richer capability splits (notably v4, which split the runtime into twelve `io.*` capabilities) and richer concurrency primitives. The current iteration intentionally simplifies — a single `IO` capability, fewer moving parts — to make the language's core ideas legible without the runtime decomposition dominating the page.

6.1.2 The simplifications are not commitments. Splitting `IO` into finer capabilities, adding first-class capability values, and expanding the type system are all on the table. They are deferred so that the conceptual core can be evaluated on its own terms first.

6.1.3 See [archive/capability-language-design-v4.md](./archive/capability-language-design-v4.md) for the previous iteration.
