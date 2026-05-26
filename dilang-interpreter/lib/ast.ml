type ident = string
type type_name = string

type literal =
  | LInt of int64
  | LStr of string
  | LBool of bool
  | LUnit

type bin_op =
  | Add | Sub | Mul | Div
  | Eq | Neq | Lt | Gt | Leq | Geq

type expr =
  | Lit of literal
  | Var of ident
  | Let of { name : ident; mut : bool; rhs : expr; body : expr }
  | Block of expr list
  | Call of { fn : expr; args : expr list }
  | BinOp of bin_op * expr * expr
  | Return of expr
  | StringInterp of string_part list
  (* Stage 8 (D1): unified dotted-call form. Eval routes to capability dispatch
     when `target = Var n` and `n` is a declared capability; otherwise it
     dispatches by the runtime type of the evaluated target (`VArray.len`,
     `VArray.push`, future `VStr.*`). *)
  | MethodCall   of { target : expr; name : ident; args : expr list }
  | Provide of { entries : provide_entry list; scope : ident option; body : expr option }
  | FieldGet of { recv : expr; name : ident }
  | StructLit of { ty : type_name; fields : (ident * expr) list }
  | If           of { cond : expr; then_ : expr; else_ : expr option }
  | Raise        of { variant : ident; payload : expr list }
  | Try          of { body : expr; arms : (pattern * expr) list }
  | NullCoalesce of expr * expr
  | OptChain     of { recv : expr; name : ident }
  | Defer        of expr
  (* `Scope e` is the runtime marker for "a user-written `{ ... }`" — every
     surface block goes through the parser's `block:` rule, which wraps the
     body in `Scope`. Each `Scope` pushes a fresh defers frame and runs LIFO
     on exit (DEC-012). `Block` is the internal sequencing node produced by
     `block_of_items` and does *not* push a frame. *)
  | Scope        of expr
  | Assign       of { name : ident; rhs : expr }
  | AssignField  of { recv : expr; name : ident; rhs : expr }
  | AssignIndex  of { target : expr; idx : expr; rhs : expr }
  | Loop         of expr
  | While        of { cond : expr; body : expr }
  | For          of { var : ident; iter : expr; body : expr }
  | Break        of expr option
  | Continue
  | ArrayLit     of expr list
  | Index        of { target : expr; idx : expr }

and string_part =
  | SLit of string
  | SInterp of expr

and provide_entry =
  | Binding of { cap : ident; rhs : expr; scope : ident }
  | Using   of expr list                            (* Stage 9 — parser never emits this yet *)

and pattern =
  | PWild
  | PVar     of ident
  | PVariant of { tag : string; sub : pattern list }

type block_item =
  | BLet of { name : ident; mut : bool; rhs : expr }
  | BExpr of expr

let block_of_items items =
  let rec go = function
    | [] -> Lit LUnit
    | [BExpr e] -> e
    | [BLet { name; mut; rhs }] ->
        Let { name; mut; rhs; body = Lit LUnit }
    | BLet { name; mut; rhs } :: rest ->
        Let { name; mut; rhs; body = go rest }
    | BExpr e :: rest ->
        Block [e; go rest]
  in
  go items

type cap_method_sig = {
  m_name   : ident;
  m_params : (ident * type_name) list;
  m_ret    : type_name option;
}

type cap_decl = {
  c_name    : ident;
  c_extends : ident list;
  c_methods : cap_method_sig list;
}

type struct_decl = {
  s_name   : type_name;
  s_fields : (ident * type_name) list;
}

type impl_method = {
  im_name   : ident;
  im_params : (ident * type_name) list;
  im_ret    : type_name option;
  im_body   : expr;
}

type impl_decl = {
  for_ty        : type_name;
  caps          : ident list;
  priv_requires : ident list;
  methods       : impl_method list;
}

type fn_decl = {
  name     : ident;
  params   : (ident * type_name) list;
  ret      : type_name option;
  requires : ident list;
  body     : expr;
}

type enum_variant = { v_name : ident; v_payload : (ident * type_name) list }
type enum_decl    = { e_name : type_name; e_params : ident list; e_variants : enum_variant list }

type decl =
  | DFn     of fn_decl
  | DCap    of cap_decl
  | DStruct of struct_decl
  | DImpl   of impl_decl
  | DEnum   of enum_decl

type program = decl list
