let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let len = in_channel_length ic in
       really_input_string ic len)

let stage_test ~name () =
  let di     = "stages/" ^ name ^ ".di" in
  let expect = "expect/" ^ name ^ ".txt" in
  let buf = Buffer.create 256 in
  Dilang.Driver.run_file_to_buffer di buf;
  let actual   = Buffer.contents buf in
  let expected = read_file expect in
  Alcotest.(check string) name expected actual

let run_string src =
  let buf = Buffer.create 256 in
  Dilang.Driver.run_string_to_buffer src buf;
  Buffer.contents buf

let check_raises_substr label substr thunk =
  try
    let _ = thunk () in
    Alcotest.failf "%s: expected Failure containing %S, but no exception" label substr
  with
  | Failure msg when msg = substr || (try ignore (Str.search_forward (Str.regexp_string substr) msg 0); true with Not_found -> false) -> ()
  | Failure msg ->
      Alcotest.failf "%s: expected substring %S, got %S" label substr msg

(* --- generated stress programs ----------------------------------------- *)

let stress_long_block () =
  (* 500 `print(...)` statements in main. Exercises long Block lists,
     parser/eval iteration without recursion. *)
  let b = Buffer.create (32 * 500) in
  Buffer.add_string b "fn main() {\n";
  for i = 0 to 499 do
    Buffer.add_string b (Printf.sprintf "    print(%d)\n" i)
  done;
  Buffer.add_string b "}\n";
  let out = run_string (Buffer.contents b) in
  let lines = String.split_on_char '\n' out in
  (* 500 lines + trailing empty string after final newline *)
  Alcotest.(check int) "line count" 501 (List.length lines);
  Alcotest.(check string) "first" "0"   (List.nth lines 0);
  Alcotest.(check string) "last"  "499" (List.nth lines 499)

let stress_deep_addition () =
  (* Sum of 200 `1`s. Tests deeply-nested left-associative BinOp tree. *)
  let n = 200 in
  let b = Buffer.create (4 * n + 64) in
  Buffer.add_string b "fn main() { print(";
  for i = 0 to n - 1 do
    if i > 0 then Buffer.add_string b " + ";
    Buffer.add_string b "1"
  done;
  Buffer.add_string b ") }\n";
  let out = run_string (Buffer.contents b) in
  Alcotest.(check string) "sum of 200 ones" "200\n" out

let stress_deep_parens () =
  let n = 200 in
  let b = Buffer.create (4 * n + 64) in
  Buffer.add_string b "fn main() { print(";
  for _ = 1 to n do Buffer.add_char b '(' done;
  Buffer.add_string b "42";
  for _ = 1 to n do Buffer.add_char b ')' done;
  Buffer.add_string b ") }\n";
  let out = run_string (Buffer.contents b) in
  Alcotest.(check string) "deeply parenthesised int" "42\n" out

let stress_deep_lets () =
  (* 300 nested `let` bindings, each referencing the previous, ending in
     a print. Tests env chain walking + AST nesting. *)
  let n = 300 in
  let b = Buffer.create (32 * n + 64) in
  Buffer.add_string b "fn main() {\n";
  Buffer.add_string b "    let x0 = 0\n";
  for i = 1 to n do
    Buffer.add_string b (Printf.sprintf "    let x%d = x%d + 1\n" i (i - 1))
  done;
  Buffer.add_string b (Printf.sprintf "    print(x%d)\n" n);
  Buffer.add_string b "}\n";
  let out = run_string (Buffer.contents b) in
  Alcotest.(check string) "deep lets" (string_of_int n ^ "\n") out

let stress_many_cap_calls () =
  (* 500 Logger.info calls in a single with frame. *)
  let n = 500 in
  let b = Buffer.create (40 * n + 256) in
  Buffer.add_string b
    "capability Logger { fn info(msg: Str) }\n\
     fn main() {\n\
     \    with [ Logger <- StdoutLogger @ 'Process ] @ 'Process {\n";
  for i = 1 to n do
    Buffer.add_string b (Printf.sprintf "        Logger.info(\"line %d\")\n" i)
  done;
  Buffer.add_string b "    }\n}\n";
  let out = run_string (Buffer.contents b) in
  let lines = String.split_on_char '\n' out in
  Alcotest.(check int) "line count" (n + 1) (List.length lines);
  Alcotest.(check string) "first" "line 1"   (List.nth lines 0);
  Alcotest.(check string) "last"  (Printf.sprintf "line %d" n) (List.nth lines (n - 1))

let stress_nested_with () =
  (* 50 levels of nested `with` blocks, each re-binding Logger and
     calling info once. Tests cap_frame stack growth + Eio.Switch.run
     nesting. *)
  let n = 50 in
  let b = Buffer.create (64 * n + 256) in
  Buffer.add_string b
    "capability Logger { fn info(msg: Str) }\n\
     fn main() {\n";
  for i = 1 to n do
    Buffer.add_string b
      (Printf.sprintf "%swith [ Logger <- StdoutLogger @ 'Process ] @ 'Process {\n"
         (String.make (i * 4) ' '));
    Buffer.add_string b
      (Printf.sprintf "%sLogger.info(\"level %d\")\n"
         (String.make ((i + 1) * 4) ' ') i);
  done;
  for i = n downto 1 do
    Buffer.add_string b (Printf.sprintf "%s}\n" (String.make (i * 4) ' '))
  done;
  Buffer.add_string b "}\n";
  let out = run_string (Buffer.contents b) in
  let lines = String.split_on_char '\n' out in
  Alcotest.(check int) "line count" (n + 1) (List.length lines);
  Alcotest.(check string) "first" "level 1"  (List.nth lines 0);
  Alcotest.(check string) "last"  (Printf.sprintf "level %d" n) (List.nth lines (n - 1))

let stress_long_extends_chain () =
  (* Chain of N (>=10) caps each extending the previous. A single binding
     under the top-most cap resolves a call to the base cap's method. *)
  let n = 12 in
  let b = Buffer.create 4096 in
  Buffer.add_string b "capability C0 { fn ping(msg: Str) }\n";
  for i = 1 to n - 1 do
    Buffer.add_string b (Printf.sprintf "capability C%d extends C%d {}\n" i (i - 1))
  done;
  Buffer.add_string b "struct Pinger {}\n";
  Buffer.add_string b "impl C0 for Pinger {\n";
  Buffer.add_string b "    fn ping(msg: Str) { print(\"got:${msg}\") }\n";
  Buffer.add_string b "}\n";
  Buffer.add_string b (Printf.sprintf
    "fn main() {\n\
     \    with [ C%d <- Pinger @ 'Process ] @ 'Process { C0.ping(\"chain\") }\n\
     }\n" (n - 1));
  let out = run_string (Buffer.contents b) in
  Alcotest.(check string) "long extends chain" "got:chain\n" out

let stress_wide_with_chain () =
  (* 20 bindings where each cap C_i's impl info() calls C_{i-1}.info().
     Verifies left-to-right cap-env capture across a long frame. *)
  let n = 20 in
  let b = Buffer.create 8192 in
  for i = 0 to n - 1 do
    Buffer.add_string b
      (Printf.sprintf "capability C%d { fn info(msg: Str) }\n" i)
  done;
  Buffer.add_string b "struct Base {}\n";
  Buffer.add_string b "impl C0 for Base { fn info(msg: Str) { print(\"0:${msg}\") } }\n";
  for i = 1 to n - 1 do
    Buffer.add_string b (Printf.sprintf "struct S%d {}\n" i);
    Buffer.add_string b
      (Printf.sprintf "impl C%d for S%d {\n\
                       \    fn info(msg: Str) { C%d.info(\"${msg}\") }\n\
                       }\n" i i (i - 1))
  done;
  Buffer.add_string b "fn main() {\n    with [\n";
  Buffer.add_string b "        C0 <- Base @ 'Process\n";
  for i = 1 to n - 1 do
    Buffer.add_string b
      (Printf.sprintf "        C%d <- S%d @ 'Process\n" i i)
  done;
  Buffer.add_string b
    (Printf.sprintf "    ] @ 'Process { C%d.info(\"go\") }\n}\n" (n - 1));
  let out = run_string (Buffer.contents b) in
  Alcotest.(check string) "wide with chain" "0:go\n" out

let stress_many_fields () =
  (* Struct with K fields. The method concatenates all self.f_i. *)
  let k = 20 in
  let b = Buffer.create 4096 in
  Buffer.add_string b "capability Cat { fn shout() }\n";
  Buffer.add_string b "struct Big { ";
  for i = 0 to k - 1 do
    if i > 0 then Buffer.add_string b ", ";
    Buffer.add_string b (Printf.sprintf "f%d: Str" i)
  done;
  Buffer.add_string b " }\nimpl Cat for Big {\n    fn shout() { print(\"";
  for i = 0 to k - 1 do
    Buffer.add_string b (Printf.sprintf "${self.f%d}" i)
  done;
  Buffer.add_string b "\") }\n}\nfn main() {\n    with [ Cat <- Big { ";
  for i = 0 to k - 1 do
    if i > 0 then Buffer.add_string b ", ";
    Buffer.add_string b (Printf.sprintf "f%d: \"%d\"" i i)
  done;
  Buffer.add_string b " } @ 'Process ] @ 'Process { Cat.shout() }\n}\n";
  let out = run_string (Buffer.contents b) in
  let expected = Buffer.create 64 in
  for i = 0 to k - 1 do
    Buffer.add_string expected (string_of_int i)
  done;
  Buffer.add_char expected '\n';
  Alcotest.(check string) "many fields" (Buffer.contents expected) out

let stress_deep_if_else () =
  (* 60 levels of `if ... else if ...` chained; only the deepest branch matches. *)
  let n = 60 in
  let b = Buffer.create (64 * n + 64) in
  Buffer.add_string b "fn main() {\n    let x = 60\n    let r = if x == 0 { 0 }";
  for i = 1 to n - 1 do
    Buffer.add_string b (Printf.sprintf " else if x == %d { %d }" i i)
  done;
  Buffer.add_string b " else { 999 }\n    print(r)\n}\n";
  let out = run_string (Buffer.contents b) in
  Alcotest.(check string) "deep if/else if" "999\n" out

let stress_deep_raise () =
  (* Recursion ~50 frames deep; innermost raise; single outer try. *)
  let n = 50 in
  let b = Buffer.create 1024 in
  Buffer.add_string b "enum E { Boom(d: I64) }\n";
  Buffer.add_string b
    (Printf.sprintf
       "fn descend(d: I64) -> I64 raises {E} {\n\
       \    if d == %d { raise Boom(d) }\n\
       \    descend(d + 1)\n\
       }\n" n);
  Buffer.add_string b
    "fn main() {\n\
    \    try {\n\
    \        let _r = descend(0)\n\
    \        print(\"nope\")\n\
    \    } catch {\n\
    \        Boom(depth) -> print(\"boom at ${depth}\")\n\
    \    }\n\
    }\n";
  let out = run_string (Buffer.contents b) in
  Alcotest.(check string) "deep raise" (Printf.sprintf "boom at %d\n" n) out

let stress_long_optchain () =
  (* Chain `?.next` 10 deep through optional-field-yielding structs.
     Stage-5 only supports single-step ?. (no nested at parse, but eval
     handles a flattened chain via repeated wrapping). *)
  let n = 6 in
  let b = Buffer.create 2048 in
  for i = 0 to n - 1 do
    Buffer.add_string b
      (Printf.sprintf "struct N%d { next: N%d? }\n" i (i + 1))
  done;
  Buffer.add_string b (Printf.sprintf "struct N%d { tail: Str? }\n" n);
  Buffer.add_string b "fn main() {\n";
  (* build innermost first *)
  Buffer.add_string b
    (Printf.sprintf "    let v%d = N%d { tail: Some(\"end\") }\n" n n);
  for i = n - 1 downto 0 do
    Buffer.add_string b
      (Printf.sprintf "    let v%d = N%d { next: Some(v%d) }\n" i i (i + 1))
  done;
  (* chain ?.next from v0 down *)
  Buffer.add_string b "    let r = Some(v0)";
  for _ = 0 to n - 1 do
    Buffer.add_string b "?.next"
  done;
  Buffer.add_string b "?.tail ?? \"absent\"\n    print(r)\n}\n";
  let out = run_string (Buffer.contents b) in
  Alcotest.(check string) "long optchain" "end\n" out

let stress_defers_100 () =
  (* 100 defers in one function. Tag each by its registration index and verify
     LIFO ordering: defer #99 fires first, defer #0 fires last. *)
  let n = 100 in
  let b = Buffer.create (32 * n + 64) in
  Buffer.add_string b "fn many() {\n";
  for i = 0 to n - 1 do
    Buffer.add_string b (Printf.sprintf "    defer print(\"d%d\")\n" i)
  done;
  Buffer.add_string b "    print(\"body\")\n}\nfn main() { many() }\n";
  let out = run_string (Buffer.contents b) in
  let lines = String.split_on_char '\n' out in
  Alcotest.(check int) "line count" (n + 2) (List.length lines);
  Alcotest.(check string) "body first" "body" (List.nth lines 0);
  Alcotest.(check string) "newest defer fires first"
    (Printf.sprintf "d%d" (n - 1)) (List.nth lines 1);
  Alcotest.(check string) "oldest defer fires last"
    "d0" (List.nth lines n)

let stress_deep_defer_raise () =
  (* Recursion ~50 frames deep; each frame registers one defer tagged with its
     depth; deepest frame raises; outer try catches. Defers fire in reverse-
     stack order (deepest first). *)
  let n = 50 in
  let b = Buffer.create 2048 in
  Buffer.add_string b "enum E { Boom }\n";
  Buffer.add_string b
    (Printf.sprintf
       "fn descend(d: I64) raises {E} {\n\
       \    defer print(\"defer d=${d}\")\n\
       \    if d == %d { raise Boom }\n\
       \    descend(d + 1)\n\
       }\n" n);
  Buffer.add_string b
    "fn main() {\n\
    \    try { descend(0) } catch { Boom -> print(\"caught\") }\n\
    }\n";
  let out = run_string (Buffer.contents b) in
  let lines = String.split_on_char '\n' out in
  (* n+1 frames (depths 0..n) each print one defer line, then "caught".
     With trailing newline, split yields (n+1)+1+1 = n+3 elements (last empty). *)
  Alcotest.(check int) "line count" (n + 3) (List.length lines);
  Alcotest.(check string) "deepest first"
    (Printf.sprintf "defer d=%d" n) (List.nth lines 0);
  Alcotest.(check string) "shallowest last"
    "defer d=0" (List.nth lines n);
  Alcotest.(check string) "caught after defers"
    "caught" (List.nth lines (n + 1))

let stress_defer_return_in_if () =
  (* Defer registered, then `return` from inside an `if` branch. Defer must
     still fire on that exit path. *)
  let src =
    "fn pick(x: I64) -> Str {\n\
    \    defer print(\"defer fired\")\n\
    \    if x == 0 { return \"zero\" }\n\
    \    print(\"after if\")\n\
    \    return \"nonzero\"\n\
    }\n\
     fn main() {\n\
    \    print(pick(0))\n\
    \    print(pick(1))\n\
    }\n"
  in
  let out = run_string src in
  Alcotest.(check string) "defer + return in if"
    "defer fired\nzero\nafter if\ndefer fired\nnonzero\n" out

(* --- Stage 7 stress: assignment + loops ---------------------------------- *)

let stress_while_10k () =
  (* 10,000-iteration `while` counter. Verifies that long-running loops
     don't blow the OCaml stack — `while` is implemented as an OCaml `while`
     loop in eval, so this is really a per-iteration allocation check. *)
  let n = 10_000 in
  let src = Printf.sprintf
    "fn main() {\n\
    \    let mut i = 0\n\
    \    while i < %d { i = i + 1 }\n\
    \    print(i)\n\
    }\n" n
  in
  let out = run_string src in
  Alcotest.(check string) "10k iter" (string_of_int n ^ "\n") out

let stress_50_nested_loops_in_fns () =
  (* 50 fns each running a `loop { ... break }` that prints once. Verifies
     that activation frames + loop frames compose. *)
  let n = 50 in
  let b = Buffer.create 4096 in
  for i = 1 to n do
    Buffer.add_string b
      (Printf.sprintf
        "fn f%d() {\n\
        \    let mut k = 0\n\
        \    loop {\n\
        \        if k >= 1 { break }\n\
        \        print(\"f%d\")\n\
        \        k = k + 1\n\
        \    }\n\
        }\n" i i)
  done;
  Buffer.add_string b "fn main() {\n";
  for i = 1 to n do
    Buffer.add_string b (Printf.sprintf "    f%d()\n" i)
  done;
  Buffer.add_string b "}\n";
  let out = run_string (Buffer.contents b) in
  let lines = String.split_on_char '\n' out in
  Alcotest.(check int) "line count" (n + 1) (List.length lines);
  Alcotest.(check string) "first" "f1" (List.nth lines 0);
  Alcotest.(check string) "last"  (Printf.sprintf "f%d" n) (List.nth lines (n - 1))

let stress_loop_defers_100 () =
  (* 100-iteration loop registering one defer per iteration. Each iteration's
     defer fires at the iteration's scope exit, interleaved with body prints.
     The defer body reads the live `i` (DEC-012 capture-at-fire-time), so the
     k-th defer prints the value `i` had AFTER the increment. *)
  let n = 100 in
  let src = Printf.sprintf
    "fn main() {\n\
    \    let mut i = 0\n\
    \    let mut k = 0\n\
    \    loop {\n\
    \        if k >= %d { break }\n\
    \        defer print(\"end ${i}\")\n\
    \        print(\"body ${k}\")\n\
    \        i = i + 1\n\
    \        k = k + 1\n\
    \    }\n\
    \    print(\"done\")\n\
    }\n" n
  in
  let out = run_string src in
  let lines = String.split_on_char '\n' out in
  (* 100 body lines + 100 end lines + "done" + trailing empty = 202 *)
  Alcotest.(check int) "line count" (2 * n + 2) (List.length lines);
  Alcotest.(check string) "first body" "body 0" (List.nth lines 0);
  Alcotest.(check string) "first end"  "end 1"  (List.nth lines 1);
  Alcotest.(check string) "last body"
    (Printf.sprintf "body %d" (n - 1)) (List.nth lines (2 * n - 2));
  Alcotest.(check string) "last end"
    (Printf.sprintf "end %d" n) (List.nth lines (2 * n - 1));
  Alcotest.(check string) "done" "done" (List.nth lines (2 * n))

let stress_loop_string_accumulator () =
  (* `loop`-as-expression returning a string built across 20 iterations via
     a mutable accumulator then `break acc`. *)
  let n = 20 in
  let src = Printf.sprintf
    "fn main() {\n\
    \    let mut i = 0\n\
    \    let mut acc = \"\"\n\
    \    let r = loop {\n\
    \        if i >= %d { break acc }\n\
    \        acc = \"${acc}[${i}]\"\n\
    \        i = i + 1\n\
    \    }\n\
    \    print(r)\n\
    }\n" n
  in
  let out = run_string src in
  let expected = Buffer.create 128 in
  for i = 0 to n - 1 do
    Buffer.add_string expected (Printf.sprintf "[%d]" i)
  done;
  Buffer.add_char expected '\n';
  Alcotest.(check string) "loop accumulator" (Buffer.contents expected) out

(* --- Stage 8 stress: arrays + iteration --------------------------------- *)

let stress_array_push_1k () =
  (* Push 1000 ints into an array, then read length + a few indices. *)
  let n = 1000 in
  let src = Printf.sprintf
    "fn main() {\n\
    \    let xs = []\n\
    \    let mut i = 0\n\
    \    while i < %d {\n\
    \        xs.push(i)\n\
    \        i = i + 1\n\
    \    }\n\
    \    print(xs.len())\n\
    \    print(xs[0])\n\
    \    print(xs[999])\n\
    }\n" n
  in
  let out = run_string src in
  Alcotest.(check string) "1k push" "1000\n0\n999\n" out

let stress_for_10k () =
  (* Build a 10k-element array and sum it with `for`. *)
  let n = 10_000 in
  let src = Printf.sprintf
    "fn main() {\n\
    \    let xs = []\n\
    \    let mut i = 0\n\
    \    while i < %d {\n\
    \        xs.push(i)\n\
    \        i = i + 1\n\
    \    }\n\
    \    let mut sum = 0\n\
    \    for x in xs { sum = sum + x }\n\
    \    print(sum)\n\
    }\n" n
  in
  let out = run_string src in
  let expected_sum = n * (n - 1) / 2 in
  Alcotest.(check string) "10k for" (string_of_int expected_sum ^ "\n") out

let stress_interpolation () =
  let n = 200 in
  let b = Buffer.create (40 * n) in
  Buffer.add_string b "fn main() {\n    let x = 7\n    print(\"";
  for i = 1 to n do
    Buffer.add_string b (Printf.sprintf "[%d:${x + %d}]" i i)
  done;
  Buffer.add_string b "\")\n}\n";
  let out = run_string (Buffer.contents b) in
  let expected = Buffer.create (10 * n) in
  for i = 1 to n do
    Buffer.add_string expected (Printf.sprintf "[%d:%d]" i (7 + i))
  done;
  Buffer.add_char expected '\n';
  Alcotest.(check string) "huge interp" (Buffer.contents expected) out

(* --- RFC-001 `with` scoped wiring -------------------------------------- *)

let rfc_with_default_scope () =
  let out =
    run_string
      "capability Logger { fn info(msg: Str) }\n\
       fn main() {\n\
       \    with [ Logger <- StdoutLogger ] @ 'Process {\n\
       \        Logger.info(\"x\")\n\
       \    }\n\
       }\n"
  in
  Alcotest.(check string) "with default scope" "x\n" out

let rfc_with_explicit_binding_scope () =
  let out =
    run_string
      "capability Logger { fn info(msg: Str) }\n\
       fn main() {\n\
       \    with [ Logger <- StdoutLogger @ 'Process ] {\n\
       \        Logger.info(\"x\")\n\
       \    }\n\
       }\n"
  in
  Alcotest.(check string) "with explicit binding scope" "x\n" out

let rfc_with_missing_scope () =
  check_raises_substr "with missing scope" "is missing a scope"
    (fun () ->
      run_string
        "capability Logger { fn info(msg: Str) }\n\
         fn main() {\n\
         \    with [ Logger <- StdoutLogger ] {\n\
         \        Logger.info(\"x\")\n\
         \    }\n\
         }\n")

let rfc_with_nested_shadowing () =
  let out =
    run_string
      "capability Logger { fn info(msg: Str) }\n\
       struct Outer {}\n\
       impl Logger for Outer { fn info(msg: Str) { print(\"outer:${msg}\") } }\n\
       struct Inner {}\n\
       impl Logger for Inner { fn info(msg: Str) { print(\"inner:${msg}\") } }\n\
       fn main() {\n\
       \    with [ Logger <- Outer ] @ 'Process {\n\
       \        Logger.info(\"x\")\n\
       \        with [ Logger <- Inner ] @ 'Process { Logger.info(\"x\") }\n\
       \        Logger.info(\"x\")\n\
       \    }\n\
       }\n"
  in
  Alcotest.(check string) "with nested shadowing"
    "outer:x\ninner:x\nouter:x\n" out

let rfc_with_left_to_right_capture () =
  let out =
    run_string
      "capability A { fn a() }\n\
       capability B { fn b() }\n\
       struct AImpl {}\n\
       impl A for AImpl { fn a() { print(\"a\") } }\n\
       struct BImpl {}\n\
       impl B for BImpl { fn b() { A.a() print(\"b\") } }\n\
       fn main() {\n\
       \    with [\n\
       \        A <- AImpl\n\
       \        B <- BImpl\n\
       \    ] @ 'Process { B.b() }\n\
       }\n"
  in
  Alcotest.(check string) "with left-to-right capture" "a\nb\n" out

let rfc_scope_and_cap_lifetime_parse () =
  let out =
    run_string
      "scope 'Request under 'Process\n\
       capability RequestCtx @ 'Request { fn id() -> Str }\n\
       fn answer() -> I64 = 42\n\
       fn main() { print(\"ok ${answer()}\") }\n"
  in
  Alcotest.(check string) "scope/cap lifetime parse" "ok 42\n" out

let rfc_with_wiring_value_runtime_error () =
  check_raises_substr "with wiring value" "Wiring values (`with [...]` without a body)"
    (fun () ->
      run_string
        "capability Logger { fn info(msg: Str) }\n\
         fn main() {\n\
         \    let _w = with [ Logger <- StdoutLogger @ 'Process ]\n\
         }\n")

let rfc_with_spread_runtime_error () =
  check_raises_substr "with spread" "`with` spread entries are not supported"
    (fun () ->
      run_string
        "fn main() {\n\
         \    with [ ...42 ] @ 'Process { print(\"nope\") }\n\
         }\n")

(* --- negative paths ----------------------------------------------------- *)

let neg_cap_not_in_scope () =
  check_raises_substr "cap not in scope" "capability Logger not in scope"
    (fun () ->
      run_string
        "capability Logger { fn info(msg: Str) }\n\
         fn main() { Logger.info(\"oops\") }\n")

let neg_unknown_method () =
  check_raises_substr "unknown method" "has no method bogus"
    (fun () ->
      run_string
        "capability Logger { fn info(msg: Str) }\n\
         fn main() {\n\
         \    with [ Logger <- StdoutLogger @ 'Process ] @ 'Process {\n\
         \        Logger.bogus(\"x\")\n\
         \    }\n\
         }\n")

let neg_arity_mismatch () =
  check_raises_substr "arity" "arity mismatch"
    (fun () ->
      run_string
        "fn add(a: I64, b: I64) -> I64 { a + b }\n\
         fn main() { print(add(1)) }\n")

let neg_div_by_zero () =
  check_raises_substr "division" "division by zero"
    (fun () -> run_string "fn main() { print(1 / 0) }\n")

let neg_unknown_function () =
  check_raises_substr "unknown function" "unknown function: nope"
    (fun () -> run_string "fn main() { nope(1) }\n")

let neg_with_non_impl () =
  check_raises_substr "non-impl rhs" "did not evaluate to an impl"
    (fun () ->
      run_string
        "capability Logger { fn info(msg: Str) }\n\
         fn main() {\n\
         \    with [ Logger <- 42 @ 'Process ] @ 'Process {\n\
         \        Logger.info(\"x\")\n\
         \    }\n\
         }\n")

let neg_type_error_binop () =
  check_raises_substr "type error" "type error"
    (fun () -> run_string "fn main() { print(1 + \"x\") }\n")

let neg_with_forward_ref () =
  (* A's RHS uses B, but B is declared later in the same with block. *)
  check_raises_substr "forward ref" "capability B not in scope"
    (fun () ->
      run_string
        "capability A { fn a() }\n\
         capability B { fn b() -> Str }\n\
         struct AImpl {}\n\
         impl A for AImpl {\n\
         \    requires {B}\n\
         \    fn a() { print(B.b()) }\n\
         }\n\
         struct BImpl {}\n\
         impl B for BImpl {\n\
         \    fn b() -> Str { \"hi\" }\n\
         }\n\
         struct UsesB {}\n\
         impl A for UsesB {\n\
         \    fn a() { print(B.b()) }\n\
         }\n\
         fn main() {\n\
         \    with [\n\
         \        A <- UsesB @ 'Process,\n\
         \        B <- BImpl @ 'Process\n\
         \    ] @ 'Process { A.a() }\n\
         }\n")

let neg_struct_missing_field () =
  check_raises_substr "missing field"
    "struct PrefixedLogger is missing field prefix"
    (fun () ->
      run_string
        "capability Logger { fn info(msg: Str) }\n\
         struct PrefixedLogger { prefix: Str }\n\
         impl Logger for PrefixedLogger {\n\
         \    fn info(msg: Str) { print(self.prefix) }\n\
         }\n\
         fn main() {\n\
         \    with [ Logger <- PrefixedLogger {} @ 'Process ] @ 'Process {\n\
         \        Logger.info(\"x\")\n\
         \    }\n\
         }\n")

let neg_struct_unknown_field () =
  check_raises_substr "unknown field"
    "struct PrefixedLogger has no field bogus"
    (fun () ->
      run_string
        "capability Logger { fn info(msg: Str) }\n\
         struct PrefixedLogger { prefix: Str }\n\
         impl Logger for PrefixedLogger {\n\
         \    fn info(msg: Str) { print(self.prefix) }\n\
         }\n\
         fn main() {\n\
         \    with [ Logger <- PrefixedLogger { prefix: \"x\", bogus: \"y\" } @ 'Process ] @ 'Process {\n\
         \        Logger.info(\"x\")\n\
         \    }\n\
         }\n")

let neg_missing_impl_method () =
  check_raises_substr "missing method" "has no method info"
    (fun () ->
      run_string
        "capability Logger { fn info(msg: Str) }\n\
         struct Empty {}\n\
         impl Logger for Empty {}\n\
         fn main() {\n\
         \    with [ Logger <- Empty @ 'Process ] @ 'Process {\n\
         \        Logger.info(\"x\")\n\
         \    }\n\
         }\n")

let neg_undeclared_field () =
  check_raises_substr "undeclared field" "no field nope"
    (fun () ->
      run_string
        "capability Logger { fn info(msg: Str) }\n\
         struct PrefixedLogger { prefix: Str }\n\
         impl Logger for PrefixedLogger {\n\
         \    fn info(msg: Str) { print(self.nope) }\n\
         }\n\
         fn main() {\n\
         \    with [ Logger <- PrefixedLogger { prefix: \"x\" } @ 'Process ] @ 'Process {\n\
         \        Logger.info(\"y\")\n\
         \    }\n\
         }\n")

let neg_unknown_variant_in_catch () =
  check_raises_substr "unknown variant" "uncaught raise: A"
    (fun () ->
      run_string
        "enum E { A }\n\
         fn main() {\n\
         \    try { raise A } catch { Bogus -> print(\"never\") }\n\
         }\n")

let neg_unmatched_catch_propagates () =
  check_raises_substr "unmatched catch" "uncaught raise: A"
    (fun () ->
      run_string
        "enum E { A, B }\n\
         fn inner() { try { raise A } catch { B -> print(\"never\") } }\n\
         fn main() { inner() }\n")

let neg_coalesce_lhs_not_option () =
  check_raises_substr "?? lhs not Option" "?? lhs not an Option"
    (fun () ->
      run_string
        "fn main() { print(42 ?? \"fallback\") }\n")

let neg_if_cond_not_bool () =
  check_raises_substr "if cond not Bool" "if condition not Bool"
    (fun () ->
      run_string
        "fn main() { if 1 { print(\"x\") } }\n")

let neg_some_arity () =
  check_raises_substr "Some arity"
    "variant Some expects 1 argument(s), got 2"
    (fun () ->
      run_string
        "fn main() { print(Some(1, 2)) }\n")

let err_defer_body_raises_is_swallowed () =
  (* A defer body raises a `Dilang_error`. v0 policy: swallow.
     Verifies (a) the swallow doesn't break later defers in the same
     activation, (b) the inner raise doesn't propagate out of the activation.
     Defers fire LIFO, so the raising one (registered last) fires first. *)
  let src =
    "enum E { Boom }\n\
     fn noisy() {\n\
    \    defer print(\"d1\")\n\
    \    defer raise Boom\n\
    \    print(\"body\")\n\
     }\n\
     fn main() {\n\
    \    noisy()\n\
    \    print(\"after\")\n\
     }\n"
  in
  let out = run_string src in
  Alcotest.(check string) "defer raise is swallowed"
    "body\nd1\nafter\n" out

(* --- Stage 7 negatives -------------------------------------------------- *)

let neg_assign_immutable () =
  check_raises_substr "assign to immutable" "cannot assign to immutable `x`"
    (fun () ->
      run_string
        "fn main() {\n\
         \    let x = 1\n\
         \    x = 2\n\
         }\n")

let neg_assign_unbound () =
  check_raises_substr "assign unbound" "unknown name `nope`"
    (fun () ->
      run_string
        "fn main() {\n\
         \    nope = 1\n\
         }\n")

let neg_break_outside_loop () =
  check_raises_substr "break outside loop" "break outside any loop"
    (fun () ->
      run_string
        "fn main() {\n\
         \    break\n\
         }\n")

let neg_continue_outside_loop () =
  check_raises_substr "continue outside loop" "continue outside any loop"
    (fun () ->
      run_string
        "fn main() {\n\
         \    continue\n\
         }\n")

let neg_while_cond_not_bool () =
  check_raises_substr "while cond not Bool" "while condition not Bool"
    (fun () ->
      run_string
        "fn main() {\n\
         \    while 1 { print(\"x\") }\n\
         }\n")

(* --- Stage 8 negatives -------------------------------------------------- *)

let neg_index_oob () =
  check_raises_substr "index oob" "index out of bounds"
    (fun () ->
      run_string
        "fn main() {\n\
         \    let xs = [1, 2, 3]\n\
         \    print(xs[5])\n\
         }\n")

let neg_index_non_array () =
  check_raises_substr "index non-array" "indexing non-array"
    (fun () ->
      run_string
        "fn main() {\n\
         \    let x = 42\n\
         \    print(x[0])\n\
         }\n")

let neg_for_non_array () =
  check_raises_substr "for non-array" "for over non-array"
    (fun () ->
      run_string
        "fn main() {\n\
         \    for n in 42 { print(n) }\n\
         }\n")

let neg_unknown_method_value () =
  check_raises_substr "unknown method on array" "unknown method on array: bogus"
    (fun () ->
      run_string
        "fn main() {\n\
         \    let xs = [1, 2, 3]\n\
         \    xs.bogus()\n\
         }\n")

let neg_method_on_int () =
  check_raises_substr "method on int" "method len not supported"
    (fun () ->
      run_string
        "fn main() {\n\
         \    let x = 42\n\
         \    print(x.len())\n\
         }\n")

(* --- Stage 9 negatives -------------------------------------------------- *)

let neg_split_empty_sep () =
  check_raises_substr "split empty sep" "split: separator must be non-empty"
    (fun () ->
      run_string
        "fn main() {\n\
         \    print(\"abc\".split(\"\").len())\n\
         }\n")

let neg_unknown_method_string () =
  check_raises_substr "unknown method on string" "unknown method on string: bogus"
    (fun () ->
      run_string
        "fn main() {\n\
         \    print(\"abc\".bogus())\n\
         }\n")

let neg_cap_shadow () =
  check_raises_substr "cap shadow" "collides with a declared capability"
    (fun () ->
      run_string
        "capability Logger { fn info(msg: Str) }\n\
         fn main() {\n\
         \    let Logger = 42\n\
         \    print(Logger)\n\
         }\n")

let neg_field_on_non_impl () =
  check_raises_substr "field on non-impl" "field access on non-impl value"
    (fun () ->
      run_string
        "fn main() {\n\
         \    let x = 42\n\
         \    print(x.field)\n\
         }\n")

let () =
  Alcotest.run "dilang-stages"
    [ "stage1",
      [ Alcotest.test_case "01_arith"        `Quick (stage_test ~name:"01_arith")
      ; Alcotest.test_case "01b_full"        `Quick (stage_test ~name:"01b_full")
      ; Alcotest.test_case "01c_precedence"  `Quick (stage_test ~name:"01c_precedence")
      ; Alcotest.test_case "01d_equality"    `Quick (stage_test ~name:"01d_equality_types")
      ]
    ; "stage2",
      [ Alcotest.test_case "02_functions"            `Quick (stage_test ~name:"02_functions")
      ; Alcotest.test_case "02b_returns_and_interp"  `Quick (stage_test ~name:"02b_returns_and_interp")
      ; Alcotest.test_case "02c_many_params"         `Quick (stage_test ~name:"02c_many_params")
      ; Alcotest.test_case "02d_nested_blocks_lets"  `Quick (stage_test ~name:"02d_nested_blocks_and_lets")
      ]
    ; "stage3",
      [ Alcotest.test_case "03_logger"             `Quick (stage_test ~name:"03_logger")
      ; Alcotest.test_case "03b_logger_stress"     `Quick (stage_test ~name:"03b_logger_stress")
      ; Alcotest.test_case "03c_nested_with"    `Quick (stage_test ~name:"03c_nested_with")
      ; Alcotest.test_case "03d_with_locals"    `Quick (stage_test ~name:"03d_with_locals")
      ]
    ; "stage4",
      [ Alcotest.test_case "04_user_impls"        `Quick (stage_test ~name:"04_user_impls")
      ; Alcotest.test_case "04b_extends"          `Quick (stage_test ~name:"04b_extends")
      ; Alcotest.test_case "04c_chained_capture"  `Quick (stage_test ~name:"04c_chained_capture")
      ; Alcotest.test_case "04d_fields"           `Quick (stage_test ~name:"04d_fields")
      ; Alcotest.test_case "04e_multifield"       `Quick (stage_test ~name:"04e_multifield")
      ; Alcotest.test_case "04f_multi_impl"       `Quick (stage_test ~name:"04f_multi_impl")
      ; Alcotest.test_case "04g_provided_with_arg" `Quick (stage_test ~name:"04g_provided_with_arg")
      ]
    ; "stage5",
      [ Alcotest.test_case "05_errors"     `Quick (stage_test ~name:"05_errors")
      ; Alcotest.test_case "05b_if_else"   `Quick (stage_test ~name:"05b_if_else")
      ; Alcotest.test_case "05c_option"    `Quick (stage_test ~name:"05c_option")
      ; Alcotest.test_case "05d_re_raise"  `Quick (stage_test ~name:"05d_re_raise")
      ; Alcotest.test_case "05e_re_tag"    `Quick (stage_test ~name:"05e_re_tag")
      ]
    ; "stage6",
      [ Alcotest.test_case "06_defer"            `Quick (stage_test ~name:"06_defer")
      ; Alcotest.test_case "06b_lifo"            `Quick (stage_test ~name:"06b_lifo")
      ; Alcotest.test_case "06c_defer_on_raise"  `Quick (stage_test ~name:"06c_defer_on_raise")
      ; Alcotest.test_case "06d_defer_in_method" `Quick (stage_test ~name:"06d_defer_in_method")
      ; Alcotest.test_case "06e_nested_fns"      `Quick (stage_test ~name:"06e_nested_fns")
      ; Alcotest.test_case "06f_block_scoped"    `Quick (stage_test ~name:"06f_block_scoped")
      ]
    ; "stage7",
      [ Alcotest.test_case "07_assign_loops"          `Quick (stage_test ~name:"07_assign_loops")
      ; Alcotest.test_case "07b_while"                `Quick (stage_test ~name:"07b_while")
      ; Alcotest.test_case "07c_continue"             `Quick (stage_test ~name:"07c_continue")
      ; Alcotest.test_case "07d_defer_per_iteration"  `Quick (stage_test ~name:"07d_defer_per_iteration")
      ; Alcotest.test_case "07e_break_fires_defers"   `Quick (stage_test ~name:"07e_break_fires_defers")
      ; Alcotest.test_case "07f_break_in_try_runs_try_defers"
          `Quick (stage_test ~name:"07f_break_in_try_runs_try_defers")
      ; Alcotest.test_case "07g_return_through_loop"  `Quick (stage_test ~name:"07g_return_through_loop")
      ; Alcotest.test_case "07h_loop_as_expression"   `Quick (stage_test ~name:"07h_loop_as_expression")
      ; Alcotest.test_case "07i_mutate_field"         `Quick (stage_test ~name:"07i_mutate_field")
      ; Alcotest.test_case "07j_mutate_self_field"    `Quick (stage_test ~name:"07j_mutate_self_field")
      ]
    ; "stage8",
      [ Alcotest.test_case "08_arrays"              `Quick (stage_test ~name:"08_arrays")
      ; Alcotest.test_case "08b_for_break"          `Quick (stage_test ~name:"08b_for_break")
      ; Alcotest.test_case "08c_for_continue"       `Quick (stage_test ~name:"08c_for_continue")
      ; Alcotest.test_case "08d_for_defer"          `Quick (stage_test ~name:"08d_for_defer")
      ; Alcotest.test_case "08e_index_assign"       `Quick (stage_test ~name:"08e_index_assign")
      ; Alcotest.test_case "08f_method_chain"       `Quick (stage_test ~name:"08f_method_chain")
      ; Alcotest.test_case "08g_for_inside_with" `Quick (stage_test ~name:"08g_for_inside_with")
      ; Alcotest.test_case "08h_empty_push"         `Quick (stage_test ~name:"08h_empty_push")
      ]
    ; "stage9",
      [ Alcotest.test_case "09_strings"      `Quick (stage_test ~name:"09_strings")
      ; Alcotest.test_case "09b_split_edges" `Quick (stage_test ~name:"09b_split_edges")
      ; Alcotest.test_case "09c_predicates"  `Quick (stage_test ~name:"09c_predicates")
      ; Alcotest.test_case "09d_cross_stage" `Quick (stage_test ~name:"09d_cross_stage")
      ]
    ; "stress",
      [ Alcotest.test_case "long_block_500"        `Quick stress_long_block
      ; Alcotest.test_case "deep_addition_200"     `Quick stress_deep_addition
      ; Alcotest.test_case "deep_parens_200"       `Quick stress_deep_parens
      ; Alcotest.test_case "deep_lets_300"         `Quick stress_deep_lets
      ; Alcotest.test_case "many_cap_calls_500"    `Quick stress_many_cap_calls
      ; Alcotest.test_case "nested_with_50"     `Quick stress_nested_with
      ; Alcotest.test_case "long_extends_chain"    `Quick stress_long_extends_chain
      ; Alcotest.test_case "wide_with_chain"    `Quick stress_wide_with_chain
      ; Alcotest.test_case "many_fields_20"        `Quick stress_many_fields
      ; Alcotest.test_case "interpolation_200"     `Quick stress_interpolation
      ; Alcotest.test_case "deep_if_else_60"       `Quick stress_deep_if_else
      ; Alcotest.test_case "deep_raise_50"         `Quick stress_deep_raise
      ; Alcotest.test_case "long_optchain"         `Quick stress_long_optchain
      ; Alcotest.test_case "defers_100"             `Quick stress_defers_100
      ; Alcotest.test_case "deep_defer_raise_50"    `Quick stress_deep_defer_raise
      ; Alcotest.test_case "defer_return_in_if"     `Quick stress_defer_return_in_if
      ; Alcotest.test_case "while_10k"              `Quick stress_while_10k
      ; Alcotest.test_case "nested_loops_in_fns_50" `Quick stress_50_nested_loops_in_fns
      ; Alcotest.test_case "loop_defers_100"        `Quick stress_loop_defers_100
      ; Alcotest.test_case "loop_string_accumulator" `Quick stress_loop_string_accumulator
      ; Alcotest.test_case "array_push_1k"            `Quick stress_array_push_1k
      ; Alcotest.test_case "for_10k"                  `Quick stress_for_10k
      ]
    ; "rfc001",
      [ Alcotest.test_case "with_default_scope"          `Quick rfc_with_default_scope
      ; Alcotest.test_case "with_explicit_binding_scope" `Quick rfc_with_explicit_binding_scope
      ; Alcotest.test_case "with_missing_scope"          `Quick rfc_with_missing_scope
      ; Alcotest.test_case "with_nested_shadowing"       `Quick rfc_with_nested_shadowing
      ; Alcotest.test_case "with_left_to_right_capture"  `Quick rfc_with_left_to_right_capture
      ; Alcotest.test_case "scope_and_cap_lifetime_parse" `Quick rfc_scope_and_cap_lifetime_parse
      ; Alcotest.test_case "with_wiring_value_runtime_error" `Quick rfc_with_wiring_value_runtime_error
      ; Alcotest.test_case "with_spread_runtime_error"   `Quick rfc_with_spread_runtime_error
      ]
    ; "errors",
      [ Alcotest.test_case "cap_not_in_scope"    `Quick neg_cap_not_in_scope
      ; Alcotest.test_case "unknown_method"      `Quick neg_unknown_method
      ; Alcotest.test_case "arity_mismatch"      `Quick neg_arity_mismatch
      ; Alcotest.test_case "div_by_zero"         `Quick neg_div_by_zero
      ; Alcotest.test_case "unknown_function"    `Quick neg_unknown_function
      ; Alcotest.test_case "with_non_impl"    `Quick neg_with_non_impl
      ; Alcotest.test_case "type_error_binop"    `Quick neg_type_error_binop
      ; Alcotest.test_case "with_forward_ref"   `Quick neg_with_forward_ref
      ; Alcotest.test_case "struct_missing_field"  `Quick neg_struct_missing_field
      ; Alcotest.test_case "struct_unknown_field"  `Quick neg_struct_unknown_field
      ; Alcotest.test_case "missing_impl_method"   `Quick neg_missing_impl_method
      ; Alcotest.test_case "undeclared_field"      `Quick neg_undeclared_field
      ; Alcotest.test_case "field_on_non_impl"     `Quick neg_field_on_non_impl
      ; Alcotest.test_case "unknown_variant_catch" `Quick neg_unknown_variant_in_catch
      ; Alcotest.test_case "unmatched_catch"       `Quick neg_unmatched_catch_propagates
      ; Alcotest.test_case "coalesce_lhs_not_opt"  `Quick neg_coalesce_lhs_not_option
      ; Alcotest.test_case "if_cond_not_bool"      `Quick neg_if_cond_not_bool
      ; Alcotest.test_case "some_arity"            `Quick neg_some_arity
      ; Alcotest.test_case "defer_body_raises_swallowed"
          `Quick err_defer_body_raises_is_swallowed
      ; Alcotest.test_case "assign_immutable"      `Quick neg_assign_immutable
      ; Alcotest.test_case "assign_unbound"        `Quick neg_assign_unbound
      ; Alcotest.test_case "break_outside_loop"    `Quick neg_break_outside_loop
      ; Alcotest.test_case "continue_outside_loop" `Quick neg_continue_outside_loop
      ; Alcotest.test_case "while_cond_not_bool"   `Quick neg_while_cond_not_bool
      ; Alcotest.test_case "index_oob"             `Quick neg_index_oob
      ; Alcotest.test_case "index_non_array"       `Quick neg_index_non_array
      ; Alcotest.test_case "for_non_array"         `Quick neg_for_non_array
      ; Alcotest.test_case "unknown_method_value"  `Quick neg_unknown_method_value
      ; Alcotest.test_case "method_on_int"         `Quick neg_method_on_int
      ; Alcotest.test_case "split_empty_sep"       `Quick neg_split_empty_sep
      ; Alcotest.test_case "unknown_method_string" `Quick neg_unknown_method_string
      ; Alcotest.test_case "cap_shadow"            `Quick neg_cap_shadow
      ]
    ]
