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
  (* 500 Logger.info calls in a single provide frame. *)
  let n = 500 in
  let b = Buffer.create (40 * n + 256) in
  Buffer.add_string b
    "capability Logger { fn info(msg: Str) }\n\
     fn main() {\n\
     \    provide { Logger = StdoutLogger @ Process } in {\n";
  for i = 1 to n do
    Buffer.add_string b (Printf.sprintf "        Logger.info(\"line %d\")\n" i)
  done;
  Buffer.add_string b "    }\n}\n";
  let out = run_string (Buffer.contents b) in
  let lines = String.split_on_char '\n' out in
  Alcotest.(check int) "line count" (n + 1) (List.length lines);
  Alcotest.(check string) "first" "line 1"   (List.nth lines 0);
  Alcotest.(check string) "last"  (Printf.sprintf "line %d" n) (List.nth lines (n - 1))

let stress_nested_provide () =
  (* 50 levels of nested `provide` blocks, each re-binding Logger and
     calling info once. Tests cap_frame stack growth + Eio.Switch.run
     nesting. *)
  let n = 50 in
  let b = Buffer.create (64 * n + 256) in
  Buffer.add_string b
    "capability Logger { fn info(msg: Str) }\n\
     fn main() {\n";
  for i = 1 to n do
    Buffer.add_string b
      (Printf.sprintf "%sprovide { Logger = StdoutLogger @ Process } in {\n"
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
     \    provide { C%d = Pinger @ Process } in { C0.ping(\"chain\") }\n\
     }\n" (n - 1));
  let out = run_string (Buffer.contents b) in
  Alcotest.(check string) "long extends chain" "got:chain\n" out

let stress_wide_provide_chain () =
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
  Buffer.add_string b "fn main() {\n    provide {\n";
  Buffer.add_string b "        C0 = Base @ Process\n";
  for i = 1 to n - 1 do
    Buffer.add_string b
      (Printf.sprintf "        C%d = S%d @ Process\n" i i)
  done;
  Buffer.add_string b
    (Printf.sprintf "    } in { C%d.info(\"go\") }\n}\n" (n - 1));
  let out = run_string (Buffer.contents b) in
  Alcotest.(check string) "wide provide chain" "0:go\n" out

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
  Buffer.add_string b "\") }\n}\nfn main() {\n    provide { Cat = Big { ";
  for i = 0 to k - 1 do
    if i > 0 then Buffer.add_string b ", ";
    Buffer.add_string b (Printf.sprintf "f%d: \"%d\"" i i)
  done;
  Buffer.add_string b " } @ Process } in { Cat.shout() }\n}\n";
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
         \    provide { Logger = StdoutLogger @ Process } in {\n\
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

let neg_provide_non_impl () =
  check_raises_substr "non-impl rhs" "did not evaluate to an impl"
    (fun () ->
      run_string
        "capability Logger { fn info(msg: Str) }\n\
         fn main() {\n\
         \    provide { Logger = 42 @ Process } in {\n\
         \        Logger.info(\"x\")\n\
         \    }\n\
         }\n")

let neg_type_error_binop () =
  check_raises_substr "type error" "type error"
    (fun () -> run_string "fn main() { print(1 + \"x\") }\n")

let neg_provide_forward_ref () =
  (* A's RHS uses B, but B is declared later in the same provide block. *)
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
         \    provide {\n\
         \        A = UsesB @ Process,\n\
         \        B = BImpl @ Process\n\
         \    } in { A.a() }\n\
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
         \    provide { Logger = PrefixedLogger {} @ Process } in {\n\
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
         \    provide { Logger = PrefixedLogger { prefix: \"x\", bogus: \"y\" } @ Process } in {\n\
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
         \    provide { Logger = Empty @ Process } in {\n\
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
         \    provide { Logger = PrefixedLogger { prefix: \"x\" } @ Process } in {\n\
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
      ; Alcotest.test_case "03c_nested_provide"    `Quick (stage_test ~name:"03c_nested_provide")
      ; Alcotest.test_case "03d_provide_locals"    `Quick (stage_test ~name:"03d_provide_with_locals")
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
    ; "stress",
      [ Alcotest.test_case "long_block_500"        `Quick stress_long_block
      ; Alcotest.test_case "deep_addition_200"     `Quick stress_deep_addition
      ; Alcotest.test_case "deep_parens_200"       `Quick stress_deep_parens
      ; Alcotest.test_case "deep_lets_300"         `Quick stress_deep_lets
      ; Alcotest.test_case "many_cap_calls_500"    `Quick stress_many_cap_calls
      ; Alcotest.test_case "nested_provide_50"     `Quick stress_nested_provide
      ; Alcotest.test_case "long_extends_chain"    `Quick stress_long_extends_chain
      ; Alcotest.test_case "wide_provide_chain"    `Quick stress_wide_provide_chain
      ; Alcotest.test_case "many_fields_20"        `Quick stress_many_fields
      ; Alcotest.test_case "interpolation_200"     `Quick stress_interpolation
      ; Alcotest.test_case "deep_if_else_60"       `Quick stress_deep_if_else
      ; Alcotest.test_case "deep_raise_50"         `Quick stress_deep_raise
      ; Alcotest.test_case "long_optchain"         `Quick stress_long_optchain
      ; Alcotest.test_case "defers_100"             `Quick stress_defers_100
      ; Alcotest.test_case "deep_defer_raise_50"    `Quick stress_deep_defer_raise
      ; Alcotest.test_case "defer_return_in_if"     `Quick stress_defer_return_in_if
      ]
    ; "errors",
      [ Alcotest.test_case "cap_not_in_scope"    `Quick neg_cap_not_in_scope
      ; Alcotest.test_case "unknown_method"      `Quick neg_unknown_method
      ; Alcotest.test_case "arity_mismatch"      `Quick neg_arity_mismatch
      ; Alcotest.test_case "div_by_zero"         `Quick neg_div_by_zero
      ; Alcotest.test_case "unknown_function"    `Quick neg_unknown_function
      ; Alcotest.test_case "provide_non_impl"    `Quick neg_provide_non_impl
      ; Alcotest.test_case "type_error_binop"    `Quick neg_type_error_binop
      ; Alcotest.test_case "provide_forward_ref"   `Quick neg_provide_forward_ref
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
      ]
    ]
