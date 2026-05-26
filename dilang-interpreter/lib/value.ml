type value =
  | VUnit
  | VBool of bool
  | VInt  of int64
  | VStr  of string
  | VImpl of impl_value
  | VEnum of { ty : Ast.type_name; tag : string; payload : value list }
  (* Stage 8. Mutable in place; `xs.push(v)` reallocates via Array.append and
     swaps the ref. Sharing semantics: assigning `let ys = xs` aliases the
     array (both names see the same growth) because the value carries the
     same `ref`. *)
  | VArray of value array ref
  (* Stage 10: first-class closures. Captures both the lexical `env` *and* the
     capability stack `caps` at definition time, so a closure built inside a
     `provide { ... } in { ... }` still resolves its capabilities when invoked
     after that block has exited. Effect rows are not tracked this stage. *)
  | VClosure of { params : (Ast.ident * Ast.type_name option) list;
                  body   : Ast.expr;
                  env    : env;
                  caps   : cap_frame list }
  | VFn of Ast.fn_decl

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
  (* Stage 7: third element is the per-binding `mut` flag (set by `let mut`).
     Reads ignore it; `Assign` consults `Env.find_ref` to refuse writes to
     immutable bindings. *)
  values : (Ast.ident * value ref * bool) list;
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
  (* Per-activation finalizer stack. Head = most-recently-registered = first
     to fire. `call_fn` and the `DUser` arm of `CapCall` swap in a fresh ref
     when entering a user activation; defers therefore attach to the enclosing
     fn/method, never to the caller. *)
  defers            : (unit -> unit) list ref;
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
  | VArray a ->
      "[" ^ String.concat ", " (Array.to_list (Array.map to_display !a)) ^ "]"
  (* DEC-017: function values display as a fixed marker — no captured env/caps
     leaked, no identity/equality semantics implied. *)
  | VClosure _ -> "<closure>"
  | VFn f      -> "<fn " ^ f.name ^ ">"
