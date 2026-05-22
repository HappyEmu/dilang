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
     \    provide { Logger = StdoutLogger() @ Process } in {\n";
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
      (Printf.sprintf "%sprovide { Logger = StdoutLogger() @ Process } in {\n"
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
         \    provide { Logger = StdoutLogger() @ Process } in {\n\
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
    ; "stress",
      [ Alcotest.test_case "long_block_500"        `Quick stress_long_block
      ; Alcotest.test_case "deep_addition_200"     `Quick stress_deep_addition
      ; Alcotest.test_case "deep_parens_200"       `Quick stress_deep_parens
      ; Alcotest.test_case "deep_lets_300"         `Quick stress_deep_lets
      ; Alcotest.test_case "many_cap_calls_500"    `Quick stress_many_cap_calls
      ; Alcotest.test_case "nested_provide_50"     `Quick stress_nested_provide
      ; Alcotest.test_case "interpolation_200"     `Quick stress_interpolation
      ]
    ; "errors",
      [ Alcotest.test_case "cap_not_in_scope"    `Quick neg_cap_not_in_scope
      ; Alcotest.test_case "unknown_method"      `Quick neg_unknown_method
      ; Alcotest.test_case "arity_mismatch"      `Quick neg_arity_mismatch
      ; Alcotest.test_case "div_by_zero"         `Quick neg_div_by_zero
      ; Alcotest.test_case "unknown_function"    `Quick neg_unknown_function
      ; Alcotest.test_case "provide_non_impl"    `Quick neg_provide_non_impl
      ; Alcotest.test_case "type_error_binop"    `Quick neg_type_error_binop
      ]
    ]
