open Ast
open Value

exception Return_exn of value

let type_err msg = failwith ("type error: " ^ msg)

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

let rec eval (ctx : ctx) = function
  | Lit (LInt n)  -> VInt n
  | Lit (LStr s)  -> VStr s
  | Lit (LBool b) -> VBool b
  | Lit LUnit     -> VUnit
  | Var x         -> Env.lookup ctx.env x
  | Let { name; mut = _; rhs; body } ->
      let v = eval ctx rhs in
      let env' = Env.extend ctx.env name v in
      eval { ctx with env = env' } body
  | Block es ->
      List.fold_left (fun _ e -> eval ctx e) VUnit es
  | Call { fn = Var "print"; args } ->
      let vs = List.map (eval ctx) args in
      List.iter (fun v -> emit_line ctx.sink (Value.to_display v)) vs;
      VUnit
  | Call { fn = Var name; args } ->
      let argv = List.map (eval ctx) args in
      (match Hashtbl.find_opt ctx.fns name with
       | Some f -> call_fn ctx f argv
       | None ->
           (match Hashtbl.find_opt ctx.host_constructors name with
            | Some ctor -> VImpl (ctor argv)
            | None      -> failwith ("unknown function: " ^ name)))
  | Call _ ->
      failwith "first-class function calls not supported in Stage 1"
  | BinOp (op, a, b) ->
      let va = eval ctx a in
      let vb = eval ctx b in
      eval_binop op va vb
  | Return e ->
      raise (Return_exn (eval ctx e))
  | StringInterp parts ->
      let b = Buffer.create 32 in
      List.iter (function
        | SLit s    -> Buffer.add_string b s
        | SInterp e -> Buffer.add_string b (Value.to_display (eval ctx e))
      ) parts;
      VStr (Buffer.contents b)
  | Provide { entries; scope; body = Some b } ->
      Eio.Switch.run @@ fun sw ->
      let scope_name = Option.value scope ~default:"Process" in
      let bindings = List.map (fun entry ->
        match entry with
        | Binding { cap; rhs; scope = _ } ->
            (* @ Scope is parsed and stored on the entry as a label, ignored at Stage 3 *)
            (match eval ctx rhs with
             | VImpl iv -> (cap, iv)
             | _ -> failwith ("provide binding for " ^ cap ^ " did not evaluate to an impl"))
        | Using _ -> failwith "`using` is not supported in Stage 3 (Stage 9)"
      ) entries in
      let frame = { scope = scope_name; bindings; switch = sw } in
      eval { ctx with caps = frame :: ctx.caps } b
  | Provide { body = None; _ } ->
      failwith "Wiring values (provide without `in`) are not supported in Stage 3 (Stage 9)"
  | CapCall { cap; method_; args } ->
      let impl =
        match List.find_opt (fun f -> List.mem_assoc cap f.bindings) ctx.caps with
        | None   -> failwith ("capability " ^ cap ^ " not in scope")
        | Some f -> List.assoc cap f.bindings
      in
      let arg_vs = List.map (eval ctx) args in
      (match List.assoc_opt method_ impl.methods with
       | None              -> failwith ("capability " ^ cap ^ " has no method " ^ method_)
       | Some (DHost f)    -> f ctx arg_vs
       | Some (DUser _)    -> failwith "user impls not supported in Stage 3")

and call_fn (ctx : ctx) (f : fn_decl) args =
  if List.length f.params <> List.length args then
    failwith ("arity mismatch calling " ^ f.name);
  let env0 =
    List.fold_left2
      (fun env (pname, _ty) v -> Env.extend env pname v)
      Env.empty f.params args
  in
  try eval { ctx with env = env0 } f.body
  with Return_exn v -> v
