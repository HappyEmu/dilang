type value =
  | VUnit
  | VBool of bool
  | VInt  of int64
  | VStr  of string
  | VImpl of impl_value

and impl_value = {
  ty      : Ast.type_name;
  methods : (string * impl_method_dispatch) list;
  fields  : (string * value ref) list;           (* empty in Stage 3 *)
  cap_env : cap_frame list;                      (* empty in Stage 3 *)
}

and cap_frame = {
  scope    : Ast.ident;
  bindings : (Ast.ident * impl_value) list;
  switch   : Eio.Switch.t;
}

and impl_method_dispatch =
  | DHost of (ctx -> value list -> value)
  | DUser of Ast.expr                             (* Stage 4 *)

and env = {
  values : (Ast.ident * value ref) list;
}

and sink =
  | OutChan of out_channel
  | Buf     of Buffer.t

and ctx = {
  env               : env;
  fns               : (Ast.ident, Ast.fn_decl) Hashtbl.t;
  sink              : sink;
  caps              : cap_frame list;                                       (* innermost first *)
  cap_decls         : (Ast.ident, Ast.cap_decl) Hashtbl.t;
  host_constructors : (Ast.ident, value list -> impl_value) Hashtbl.t;
}

let emit_line sink s =
  match sink with
  | OutChan oc -> output_string oc s; output_char oc '\n'; flush oc
  | Buf b      -> Buffer.add_string b s; Buffer.add_char b '\n'

let to_display = function
  | VUnit   -> "()"
  | VBool b -> string_of_bool b
  | VInt  i -> Int64.to_string i
  | VStr  s -> s
  | VImpl i -> "<impl " ^ i.ty ^ ">"
