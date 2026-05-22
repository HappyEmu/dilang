open Ast
open Value

type sink =
  | OutChan of out_channel
  | Buf     of Buffer.t

let emit_line sink s =
  match sink with
  | OutChan oc -> output_string oc s; output_char oc '\n'; flush oc
  | Buf b      -> Buffer.add_string b s; Buffer.add_char b '\n'

type ctx = {
  env  : Env.t;
  fns  : (ident, fn_decl) Hashtbl.t;
  sink : sink;
}

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

let rec eval ctx = function
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
      let f =
        match Hashtbl.find_opt ctx.fns name with
        | Some f -> f
        | None   -> failwith ("unknown function: " ^ name)
      in
      let argv = List.map (eval ctx) args in
      call_fn ctx f argv
  | Call _ ->
      failwith "first-class function calls not supported in Stage 1"
  | BinOp (op, a, b) ->
      let va = eval ctx a in
      let vb = eval ctx b in
      eval_binop op va vb

and call_fn ctx f args =
  if List.length f.params <> List.length args then
    failwith ("arity mismatch calling " ^ f.name);
  let env0 =
    List.fold_left2
      (fun env (pname, _ty) v -> Env.extend env pname v)
      Env.empty f.params args
  in
  eval { ctx with env = env0 } f.body
