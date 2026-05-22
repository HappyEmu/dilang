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

and string_part =
  | SLit of string
  | SInterp of expr

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

type fn_decl = {
  name   : ident;
  params : (ident * type_name) list;
  ret    : type_name option;
  body   : expr;
}

type decl =
  | DFn of fn_decl

type program = decl list
