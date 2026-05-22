%{
open Ast
%}

%token <int64>  INT
%token <string> STR
%token <Ast.string_part list> STR_INTERP
%token <bool>   BOOL
%token <string> IDENT
%token FN LET MUT RETURN
%token CAPABILITY PROVIDE REQUIRES IN
%token STRUCT IMPL FOR EXTENDS
%token PLUS MINUS STAR SLASH
%token EQ EQEQ BANGEQ LT GT LEQ GEQ
%token LPAREN RPAREN LBRACE RBRACE
%token COMMA COLON ARROW AT DOT
%token EOF

%nonassoc RETURN
%left EQEQ BANGEQ LT GT LEQ GEQ
%left PLUS MINUS
%left STAR SLASH

%start <Ast.program> program
%start <Ast.expr>    expr_entry

%%

program:
  | ds = list(decl); EOF { ds }

expr_entry:
  | e = expr; EOF { e }

decl:
  | FN; n = IDENT; LPAREN; ps = params; RPAREN;
    r = ret_opt; req = requires_opt; b = block
    { DFn { name = n; params = ps; ret = r; requires = req; body = b } }
  | CAPABILITY; n = IDENT; ext = extends_opt; LBRACE; ms = list(cap_method); RBRACE
    { DCap { c_name = n; c_extends = ext; c_methods = ms } }
  | STRUCT; n = IDENT; LBRACE; fs = struct_fields; RBRACE
    { DStruct { s_name = n; s_fields = fs } }
  | IMPL; cs = impl_caps; FOR; t = IDENT;
    LBRACE; req = impl_requires_opt; ms = list(impl_method); RBRACE
    { DImpl { for_ty = t; caps = cs; priv_requires = req; methods = ms } }

extends_opt:
  |                                              { [] }
  | EXTENDS; xs = ident_list_nonempty            { xs }

ident_list_nonempty:
  | x = IDENT                                    { [x] }
  | x = IDENT; COMMA; rest = ident_list_nonempty { x :: rest }

struct_fields:
  |                                              { [] }
  | p = param                                    { [p] }
  | p = param; COMMA; rest = struct_fields       { p :: rest }

impl_caps:
  | x = IDENT                                    { [x] }
  | x = IDENT; PLUS; rest = impl_caps            { x :: rest }

impl_requires_opt:
  |                                              { [] }
  | REQUIRES; LBRACE; xs = ident_list; RBRACE    { xs }

impl_method:
  | FN; n = IDENT; LPAREN; ps = params; RPAREN; r = ret_opt; b = block
    { { im_name = n; im_params = ps; im_ret = r; im_body = b } }

ret_opt:
  |                       { None }
  | ARROW; t = IDENT      { Some t }

requires_opt:
  |                                              { [] }
  | REQUIRES; LBRACE; xs = ident_list; RBRACE    { xs }

ident_list:
  |                                              { [] }
  | x = IDENT                                    { [x] }
  | x = IDENT; COMMA; rest = ident_list          { x :: rest }

cap_method:
  | FN; n = IDENT; LPAREN; ps = params; RPAREN; r = ret_opt
    { { m_name = n; m_params = ps; m_ret = r } }

params:
  |                                                 { [] }
  | p = param                                       { [p] }
  | p = param; COMMA; rest = params                 { p :: rest }

param:
  | n = IDENT; COLON; t = IDENT                     { (n, t) }

block:
  | LBRACE; items = list(block_item); RBRACE        { block_of_items items }

block_item:
  | LET; m = mut_opt; n = IDENT; EQ; e = expr       { BLet { name = n; mut = m; rhs = e } }
  | e = expr                                        { BExpr e }

mut_opt:
  |     { false }
  | MUT { true  }

expr:
  | RETURN; e = expr             { Return e }
  | l = expr; PLUS;   r = expr   { BinOp (Add, l, r) }
  | l = expr; MINUS;  r = expr   { BinOp (Sub, l, r) }
  | l = expr; STAR;   r = expr   { BinOp (Mul, l, r) }
  | l = expr; SLASH;  r = expr   { BinOp (Div, l, r) }
  | l = expr; EQEQ;   r = expr   { BinOp (Eq,  l, r) }
  | l = expr; BANGEQ; r = expr   { BinOp (Neq, l, r) }
  | l = expr; LT;     r = expr   { BinOp (Lt,  l, r) }
  | l = expr; GT;     r = expr   { BinOp (Gt,  l, r) }
  | l = expr; LEQ;    r = expr   { BinOp (Leq, l, r) }
  | l = expr; GEQ;    r = expr   { BinOp (Geq, l, r) }
  | a = atom                     { a }

atom:
  | i = INT                                              { Lit (LInt i) }
  | s = STR                                              { Lit (LStr s) }
  | parts = STR_INTERP                                   { StringInterp parts }
  | b = BOOL                                             { Lit (LBool b) }
  | n = IDENT; DOT; m = IDENT; t = dot_tail
      { match t with
        | None      -> FieldGet { recv = Var n; name = m }
        | Some args -> CapCall { cap = n; method_ = m; args } }
  | n = IDENT; LBRACE; fs = struct_lit_fields; RBRACE
      { StructLit { ty = n; fields = fs } }
  | n = IDENT                                            { Var n }
  | n = IDENT; LPAREN; args = arglist; RPAREN            { Call { fn = Var n; args } }
  | LPAREN; e = expr; RPAREN                             { e }
  | b = block                                            { b }
  (* §7.3 (provide @ Scope { ... }) / §7.4 (Wiring values, no `in`) — Stage 7 / Stage 9 *)
  | PROVIDE; LBRACE; es = provide_entries; RBRACE; IN; b = block
    { Provide { entries = es; scope = None; body = Some b } }

provide_entries:
  |                                                       { [] }
  | e = provide_entry                                     { [e] }
  | e = provide_entry; COMMA; rest = provide_entries      { e :: rest }
  | e = provide_entry; rest = provide_entries_no_leading_comma  { e :: rest }

provide_entries_no_leading_comma:
  | e = provide_entry                                     { [e] }
  | e = provide_entry; COMMA; rest = provide_entries      { e :: rest }
  | e = provide_entry; rest = provide_entries_no_leading_comma  { e :: rest }

provide_entry:
  | cap = IDENT; EQ; rhs = expr; AT; sc = IDENT
    { Binding { cap; rhs; scope = sc } }

dot_tail:
  |                                                      { None }
  | LPAREN; args = arglist; RPAREN                       { Some args }

struct_lit_fields:
  |                                                                       { [] }
  | n = IDENT; COLON; e = expr; rest = struct_lit_fields_tail             { (n, e) :: rest }

struct_lit_fields_tail:
  |                                                                       { [] }
  | COMMA                                                                 { [] }
  | COMMA; n = IDENT; COLON; e = expr; rest = struct_lit_fields_tail      { (n, e) :: rest }

arglist:
  |                                                      { [] }
  | e = expr                                             { [e] }
  | e = expr; COMMA; rest = arglist                      { e :: rest }
