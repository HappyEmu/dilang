type value =
  | VUnit
  | VBool of bool
  | VInt  of int64
  | VStr  of string
  | VImpl of impl_value
  | VEnum of { ty : Ast.type_name; tag : string; payload : value list }

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
  | DUser of Ast.impl_method                      (* Stage 4 *)

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
  host_constructors : (Ast.ident, (Ast.ident * value) list -> impl_value) Hashtbl.t;
  struct_decls      : (Ast.ident, Ast.struct_decl) Hashtbl.t;
  user_constructors : (Ast.ident, (Ast.ident * value) list -> impl_value) Hashtbl.t;
  ext_of            : (Ast.ident, Ast.ident list) Hashtbl.t;
  enum_decls        : (Ast.type_name, Ast.enum_decl) Hashtbl.t;
  variants          : (Ast.ident, Ast.type_name * Ast.enum_variant) Hashtbl.t;
}

let with_cap_env (iv : impl_value) caps : impl_value = { iv with cap_env = caps }

let emit_line sink s =
  match sink with
  | OutChan oc -> output_string oc s; output_char oc '\n'; flush oc
  | Buf b      -> Buffer.add_string b s; Buffer.add_char b '\n'

let rec to_display = function
  | VUnit   -> "()"
  | VBool b -> string_of_bool b
  | VInt  i -> Int64.to_string i
  | VStr  s -> s
  | VImpl i -> "<impl " ^ i.ty ^ ">"
  | VEnum { tag; payload = []; _ } -> tag
  | VEnum { tag; payload; _ } ->
      tag ^ "(" ^ String.concat ", " (List.map to_display payload) ^ ")"
