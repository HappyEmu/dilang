open Ast
open Value

exception Return_exn of value
exception Dilang_error of { tag : string; payload : value list }
(* Stage 7 (DEC-013). Caught by `Loop` / `While`; the activation boundary
   (`call_fn`, `DUser`) converts an escaped instance into a runtime error. *)
exception Break_exn of value
exception Continue_exn

let type_err msg = failwith ("type error: " ^ msg)

(* v0 defer-raises-inside-defer policy: swallow.
   TODO: revisit (DEC entry) once we have stderr/diagnostics or panic. *)
let run_defers (thunks : (unit -> unit) list) =
  List.iter (fun t -> try t () with _ -> ()) thunks

let rec eval_binop op a b =
  match op, a, b with
  | Add, VInt x, VInt y -> VInt (Int64.add x y)
  | Sub, VInt x, VInt y -> VInt (Int64.sub x y)
  | Mul, VInt x, VInt y -> VInt (Int64.mul x y)
  | Div, VInt x, VInt y ->
      if Int64.equal y 0L then failwith "division by zero"
      else VInt (Int64.div x y)
  | Eq,  VInt x,  VInt y  -> VBool (Int64.equal x y)
  | Eq,  VStr x,  VStr y  -> VBool (String.equal x y)
  | Eq,  VBool x, VBool y -> VBool (Bool.equal x y)
  | Eq,  VUnit,   VUnit   -> VBool true
  | Neq, _,       _       ->
      (match eval_binop Eq a b with
       | VBool b -> VBool (not b)
       | _       -> type_err "Neq")
  | Lt,  VInt x, VInt y -> VBool (Int64.compare x y <  0)
  | Gt,  VInt x, VInt y -> VBool (Int64.compare x y >  0)
  | Leq, VInt x, VInt y -> VBool (Int64.compare x y <= 0)
  | Geq, VInt x, VInt y -> VBool (Int64.compare x y >= 0)
  | _ -> type_err "binop operands"

let rec match_pattern env pat v =
  match pat, v with
  | PWild, _ -> Some env
  | PVar name, _ -> Some (Env.extend env name v ~mut:false)
  | PVariant { tag; sub }, VEnum { tag = vtag; payload; _ }
      when String.equal tag vtag && List.length sub = List.length payload ->
      let rec fold env subs payloads =
        match subs, payloads with
        | [], [] -> Some env
        | sp :: rest_s, pv :: rest_p ->
            (match match_pattern env sp pv with
             | Some env' -> fold env' rest_s rest_p
             | None -> None)
        | _ -> None
      in
      fold env sub payload
  | _ -> None

let rec eval (ctx : ctx) = function
  | Lit (LInt n)  -> VInt n
  | Lit (LStr s)  -> VStr s
  | Lit (LBool b) -> VBool b
  | Lit LUnit     -> VUnit
  | Var x ->
      (* Locals shadow constructors. Bare name falls through to construct a
         fieldless user struct (DEC-009: `JsonLogger` ≡ `JsonLogger {}`) or
         host impl. Anything with required fields fails the named-fields
         check inside the constructor closure with a clear message. *)
      (try Env.lookup ctx.env x
       with Failure _ ->
         (match Hashtbl.find_opt ctx.variants x with
          | Some (enum_name, variant) when variant.v_payload = [] ->
              VEnum { ty = enum_name; tag = x; payload = [] }
          | Some _ ->
              failwith ("variant " ^ x ^ " requires payload arguments")
          | None ->
            (match Hashtbl.find_opt ctx.user_constructors x with
             | Some ctor -> VImpl (ctor [])
             | None ->
                (match Hashtbl.find_opt ctx.host_constructors x with
                 | Some ctor -> VImpl (ctor [])
                 | None      -> failwith ("unbound name: " ^ x)))))
  | Let { name; mut; rhs; body } ->
      (* Stage 8 (D1): a local `let n = ...` may not shadow a declared
         capability — `MethodCall` routes by checking `ctx.cap_decls`, so a
         shadow would silently flip method calls from capability dispatch to
         value-method dispatch. Reject early with a clean error. *)
      if Hashtbl.mem ctx.cap_decls name then
        failwith ("`" ^ name ^ "` collides with a declared capability");
      let v = eval ctx rhs in
      let env' = Env.extend ctx.env name v ~mut in
      eval { ctx with env = env' } body
  | Block es ->
      List.fold_left (fun _ e -> eval ctx e) VUnit es
  | Call { fn = Var "print"; args } ->
      let vs = List.map (eval ctx) args in
      List.iter (fun v -> emit_line ctx.sink (Value.to_display v)) vs;
      VUnit
  | Call { fn = Var name; args } ->
      (* DEC-009: `Foo(args)` is a function call only. Struct/impl
         construction uses `Foo { field: value }` (or bare `Foo` for
         fieldless), handled by Var/StructLit. Variant construction also
         flows through here: fns → variants → fail. *)
      let argv = List.map (eval ctx) args in
      (match Hashtbl.find_opt ctx.fns name with
       | Some f -> call_fn ctx f argv
       | None ->
           (match Hashtbl.find_opt ctx.variants name with
            | Some (enum_name, variant) ->
                let expected = List.length variant.v_payload in
                let got = List.length argv in
                if expected <> got then
                  failwith (Printf.sprintf
                    "variant %s expects %d argument(s), got %d"
                    name expected got);
                VEnum { ty = enum_name; tag = name; payload = argv }
            | None -> failwith ("unknown function: " ^ name)))
  | Call _ ->
      failwith "first-class function calls not supported in Stage 1"
  | BinOp (op, a, b) ->
      let va = eval ctx a in
      let vb = eval ctx b in
      eval_binop op va vb
  | Return e ->
      raise (Return_exn (eval ctx e))
  | Defer body ->
      (* Block-scoped (DEC-012). Pushes head-first onto whichever defers ref
         the innermost surrounding `Scope` swapped onto `ctx`, so the most-
         recently-registered defer in this block fires first. Body is captured
         but evaluated at fire time — reads of mutable state see scope-exit
         values. To capture-at-registration, bind to an immutable local first. *)
      let ctx_at_reg = ctx in
      let thunk () = ignore (eval ctx_at_reg body) in
      ctx.defers := thunk :: !(ctx.defers);
      VUnit
  | Scope body ->
      (* Every surface `{ ... }` reduces to a `Scope`. Swap in a fresh defers
         frame; run the body inside `Fun.protect` so the frame's defers fire
         on every exit path (fall-through, `return` / `raise` / Stage-7 break
         / continue / Stage-16 cancellation). Per-thunk exceptions are
         swallowed inside `run_defers` (DEC-011 v0). *)
      let frame = ref [] in
      let ctx' = { ctx with defers = frame } in
      Fun.protect
        ~finally:(fun () -> run_defers !frame)
        (fun () -> eval ctx' body)
  | StringInterp parts ->
      let b = Buffer.create 32 in
      List.iter (function
        | SLit s    -> Buffer.add_string b s
        | SInterp e -> Buffer.add_string b (Value.to_display (eval ctx e))
      ) parts;
      VStr (Buffer.contents b)
  | If { cond; then_; else_ } ->
      (match eval ctx cond with
       | VBool true  -> eval ctx then_
       | VBool false ->
           (match else_ with
            | Some e -> eval ctx e
            | None   -> VUnit)
       | _ -> type_err "if condition not Bool")
  | Raise { variant; payload } ->
      let payload_vs = List.map (eval ctx) payload in
      raise (Dilang_error { tag = variant; payload = payload_vs })
  | Try { body; arms } ->
      (try eval ctx body
       with Dilang_error { tag; payload } ->
         let ty =
           match Hashtbl.find_opt ctx.variants tag with
           | Some (enum_name, _) -> enum_name
           | None -> "<error>"
         in
         let v = VEnum { ty; tag; payload } in
         let rec dispatch = function
           | [] -> raise (Dilang_error { tag; payload })   (* re-raise *)
           | (pat, arm) :: rest ->
               (match match_pattern ctx.env pat v with
                | Some env' -> eval { ctx with env = env' } arm
                | None      -> dispatch rest)
         in
         dispatch arms)
  | NullCoalesce (lhs, rhs) ->
      (match eval ctx lhs with
       | VEnum { ty = "Option"; tag = "Some"; payload = [v] } -> v
       | VEnum { ty = "Option"; tag = "None"; _ }             -> eval ctx rhs
       | _ -> type_err "?? lhs not an Option")
  | OptChain { recv; name } ->
      (* §12.1: "chains do not nest Option" — if the loaded field is already
         an Option, pass it through; otherwise wrap in Some.
         Stage-10 TODO: extend with `?.method(args)` once value-method
         dispatch lands (currently only capability-style dispatch exists). *)
      (match eval ctx recv with
       | VEnum { ty = "Option"; tag = "Some"; payload = [VImpl iv] } ->
           let v =
             match List.assoc_opt name iv.fields with
             | Some r -> !r
             | None   -> failwith ("no field " ^ name ^ " on " ^ iv.ty)
           in
           (match v with
            | VEnum { ty = "Option"; _ } -> v
            | _ -> VEnum { ty = "Option"; tag = "Some"; payload = [v] })
       | VEnum { ty = "Option"; tag = "None"; _ } as none -> none
       | _ -> type_err "?. recv not Option<Impl>")
  | Provide { entries; scope; body = Some b } ->
      Eio.Switch.run @@ fun sw ->
      let scope_name = Option.value scope ~default:"Process" in
      let built = ref [] in
      List.iter (function
        | Binding { cap; rhs; scope = _ } ->
            (* Build partial frame from prior bindings so each RHS resolves
               against bindings declared *to its left* in the same provide
               block. Forward references raise "capability X not in scope". *)
            let partial = { scope = scope_name; bindings = List.rev !built; switch = sw } in
            let caps_now = partial :: ctx.caps in
            let ctx_bind = { ctx with caps = caps_now } in
            (match eval ctx_bind rhs with
             | VImpl iv -> built := (cap, with_cap_env iv caps_now) :: !built
             | _ -> failwith ("provide binding for " ^ cap ^ " did not evaluate to an impl"))
        | Using _ -> failwith "`using` is not supported in Stage 4 (Stage 9)"
      ) entries;
      let frame = { scope = scope_name; bindings = List.rev !built; switch = sw } in
      eval { ctx with caps = frame :: ctx.caps } b
  | Provide { body = None; _ } ->
      failwith "Wiring values (provide without `in`) are not supported in Stage 4 (Stage 9)"
  | MethodCall { target; name; args } ->
      (* Stage 8 (D1): one parser node, two eval paths. If the target is a
         bare name of a declared capability, route to capability dispatch;
         otherwise evaluate the target and dispatch by its runtime type. *)
      (match target with
       | Var n when Hashtbl.mem ctx.cap_decls n ->
           cap_call ctx n name args
       | _ ->
           let v = eval ctx target in
           value_method_dispatch ctx v name args)
  | StructLit { ty; fields } ->
      let evaluated = List.map (fun (n, e) -> (n, eval ctx e)) fields in
      let ctor =
        match Hashtbl.find_opt ctx.user_constructors ty with
        | Some c -> c
        | None ->
            (match Hashtbl.find_opt ctx.host_constructors ty with
             | Some c -> c
             | None   -> failwith ("unknown struct: " ^ ty))
      in
      VImpl (ctor evaluated)
  | FieldGet { recv; name } ->
      (match eval ctx recv with
       | VImpl iv ->
           (match List.assoc_opt name iv.fields with
            | Some r -> !r
            | None   -> failwith ("no field " ^ name ^ " on " ^ iv.ty))
       | _ -> type_err ("field access on non-impl value: " ^ name))
  | Assign { name; rhs } ->
      (match Env.find_ref ctx.env name with
       | Some (r, true)  -> r := eval ctx rhs; VUnit
       | Some (_, false) -> failwith ("cannot assign to immutable `" ^ name ^ "`")
       | None            -> failwith ("unknown name `" ^ name ^ "`"))
  | AssignField { recv; name; rhs } ->
      (* DEC-014 (Deferred): the eventual rule requires the receiver's root
         binding to be `mut` for field mutation to be legal. v0 does not
         enforce this — we walk straight through the field-as-ref produced
         by the struct constructor (Stage 4), so `let t = Tally{count:0};
         t.count = 1` runs successfully. Programs that rely on this will
         need a `let mut` added when the stricter rule lands. *)
      (match eval ctx recv with
       | VImpl iv ->
           (match List.assoc_opt name iv.fields with
            | Some r -> r := eval ctx rhs; VUnit
            | None   -> failwith ("no field " ^ name ^ " on " ^ iv.ty))
       | _ -> type_err ("field assignment on non-impl value: " ^ name))
  | Loop body ->
      (* DEC-013: `loop` is an expression. The only exit is `Break_exn`;
         the body's `Scope` propagates it past the body's defers, and we
         hand back the carried value. `Continue_exn` aborts the current
         iteration only — caught inside the `while true` per iteration. *)
      (try
         while true do
           try ignore (eval ctx body) with Continue_exn -> ()
         done;
         assert false
       with Break_exn v -> v)
  | While { cond; body } ->
      (try
         while
           (match eval ctx cond with
            | VBool b -> b
            | _ -> type_err "while condition not Bool")
         do
           try ignore (eval ctx body) with Continue_exn -> ()
         done
       with Break_exn _ -> ());
      VUnit
  | Break payload_opt ->
      let v =
        match payload_opt with
        | Some e -> eval ctx e
        | None   -> VUnit
      in
      raise (Break_exn v)
  | Continue ->
      raise Continue_exn
  | ArrayLit es ->
      VArray (ref (Array.of_list (List.map (eval ctx) es)))
  | Index { target; idx } ->
      (match eval ctx target, eval ctx idx with
       | VArray a, VInt i ->
           let i = Int64.to_int i in
           if i < 0 || i >= Array.length !a then
             failwith ("index out of bounds: " ^ string_of_int i);
           (!a).(i)
       | VArray _, _ -> type_err "array index not I64"
       | _ -> type_err "indexing non-array")
  | AssignIndex { target; idx; rhs } ->
      (* DEC-015 (Deferred): mutation through an indexed assignment should
         eventually require the receiver's root binding to be `mut` (matches
         DEC-014's rule for fields). v0 does not enforce this — `let xs =
         [...]; xs[0] = 1` runs successfully. Programs that rely on this
         will need a `let mut` added under the stricter rule. *)
      (match eval ctx target, eval ctx idx with
       | VArray a, VInt i ->
           let i = Int64.to_int i in
           if i < 0 || i >= Array.length !a then
             failwith ("index out of bounds: " ^ string_of_int i);
           (!a).(i) <- eval ctx rhs;
           VUnit
       | VArray _, _ -> type_err "array index not I64"
       | _ -> type_err "indexed assignment on non-array")
  | For { var; iter; body } ->
      (* Stage 8 (D2): statement-only (parallels `While`), yields `VUnit`
         (DEC-013). Catches `Break_exn` outside the loop and `Continue_exn`
         per-iteration — same shape as `While`/`Loop`. Per-iteration `Scope`
         in the body owns its defers (DEC-012). *)
      (match eval ctx iter with
       | VArray a ->
           (try
              Array.iter (fun v ->
                let env' = Env.extend ctx.env var v ~mut:false in
                try ignore (eval { ctx with env = env' } body)
                with Continue_exn -> ()
              ) !a
            with Break_exn _ -> ());
           VUnit
       | _ -> type_err "for over non-array")

and cap_call ctx cap method_ args =
  (* Stage 8 (D1): extracted from the old `CapCall` arm so `MethodCall` can
     route to it. Walks frames innermost-first; within each frame scans
     bindings in reverse declaration order ("later wins" per syntax §7.1 /
     DEC-002). Accepts the first binding whose declared cap C' has
     ext_of[C'] ∋ cap. *)
  let find_in_frame (f : cap_frame) =
    let rec scan = function
      | [] -> None
      | (c', iv) :: rest ->
          let exts =
            try Hashtbl.find ctx.ext_of c' with Not_found -> [c']
          in
          if List.mem cap exts then Some iv else scan rest
    in
    scan (List.rev f.bindings)
  in
  let rec walk = function
    | [] -> failwith ("capability " ^ cap ^ " not in scope")
    | f :: rest ->
        (match find_in_frame f with
         | Some iv -> iv
         | None    -> walk rest)
  in
  let impl = walk ctx.caps in
  let arg_vs = List.map (eval ctx) args in
  (match List.assoc_opt method_ impl.methods with
   | None              -> failwith ("capability " ^ cap ^ " has no method " ^ method_)
   | Some (DHost f)    -> f ctx arg_vs
   | Some (DUser m) ->
       if List.length m.im_params <> List.length arg_vs then
         failwith ("arity mismatch calling " ^ cap ^ "." ^ method_);
       let env0 =
         List.fold_left2
           (fun env (pname, _ty) v -> Env.extend env pname v ~mut:false)
           Env.empty m.im_params arg_vs
       in
       let env_with_self =
         if impl.fields = [] then env0
         else Env.extend env0 "self" (VImpl impl) ~mut:false
       in
       let activation_ctx =
         { ctx with env = env_with_self; caps = impl.cap_env }
       in
       try eval activation_ctx m.im_body
       with
       | Return_exn v -> v
       | Break_exn _  -> failwith "break outside any loop"
       | Continue_exn -> failwith "continue outside any loop")

and value_method_dispatch ctx v name args =
  (* Stage 8 (D1): runtime-type-driven method dispatch. Stage 9 will slot
     `VStr` arms into the same shape; later stages add streams etc. Errors
     stay specific so the test suite can pin them. *)
  match v, name, args with
  | VArray a, "len", [] ->
      VInt (Int64.of_int (Array.length !a))
  | VArray a, "push", [arg] ->
      (* DEC-015 (Deferred): no `mut` requirement on the receiver root in
         v0; `let xs = []; xs.push(1)` runs. *)
      a := Array.append !a [| eval ctx arg |];
      VUnit
  | VArray _, "len",  _ -> failwith "len() takes no arguments"
  | VArray _, "push", _ -> failwith "push() takes exactly one argument"
  | VArray _, _, _      -> failwith ("unknown method on array: " ^ name)
  | _ -> failwith ("method " ^ name ^ " not supported on this value")

and call_fn (ctx : ctx) (f : fn_decl) args =
  if List.length f.params <> List.length args then
    failwith ("arity mismatch calling " ^ f.name);
  let env0 =
    List.fold_left2
      (fun env (pname, _ty) v -> Env.extend env pname v ~mut:false)
      Env.empty f.params args
  in
  (* Defers belong to the fn body's `Scope`, not to this activation
     (DEC-012). `call_fn` only owns the `Return_exn` catch. The `Scope` that
     wraps `f.body` runs its defers before `Return_exn` propagates here.
     Stage 7: also catch `Break_exn` / `Continue_exn` that leaked past every
     enclosing loop and surface them as runtime errors (after defers ran). *)
  try eval { ctx with env = env0 } f.body
  with
  | Return_exn v -> v
  | Break_exn _  -> failwith "break outside any loop"
  | Continue_exn -> failwith "continue outside any loop"
