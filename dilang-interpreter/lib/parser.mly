%{
open Ast
%}

%token <int64>  INT
%token <string> STR
%token <Ast.string_part list> STR_INTERP
%token <bool>   BOOL
%token <string> IDENT
%token FN LET MUT RETURN
%token CAPABILITY PROVIDE REQUIRES RAISES IN
%token STRUCT IMPL FOR EXTENDS
%token IF ELSE ENUM RAISE TRY CATCH DEFER
%token PLUS MINUS STAR SLASH
%token EQ EQEQ BANGEQ LT GT LEQ GEQ
%token LPAREN RPAREN LBRACE RBRACE
%token COMMA COLON ARROW AT DOT
%token QMARK QMARK_QMARK QMARK_DOT
%token EOF

%nonassoc RETURN
%nonassoc DEFER
%right QMARK_QMARK
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
    r = ret_opt; raises_opt; req = requires_opt; b = block
    { DFn { name = n; params = ps; ret = r; requires = req; body = b } }
  | CAPABILITY; n = IDENT; ext = extends_opt; LBRACE; ms = list(cap_method); RBRACE
    { DCap { c_name = n; c_extends = ext; c_methods = ms } }
  | STRUCT; n = IDENT; LBRACE; fs = struct_fields; RBRACE
    { DStruct { s_name = n; s_fields = fs } }
  | IMPL; cs = impl_caps; FOR; t = IDENT;
    LBRACE; req = impl_requires_opt; ms = list(impl_method); RBRACE
    { DImpl { for_ty = t; caps = cs; priv_requires = req; methods = ms } }
  | ENUM; n = IDENT; ep = enum_params_opt; LBRACE; vs = enum_variants; RBRACE
    { DEnum { e_name = n; e_params = ep; e_variants = vs } }

enum_params_opt:
  |                                              { [] }
  | LT; ps = ident_list_nonempty; GT             { ps }

enum_variants:
  |                                              { [] }
  | v = enum_variant                             { [v] }
  | v = enum_variant; COMMA; rest = enum_variants                   { v :: rest }
  | v = enum_variant; rest = enum_variants_no_leading_comma         { v :: rest }

enum_variants_no_leading_comma:
  | v = enum_variant                             { [v] }
  | v = enum_variant; COMMA; rest = enum_variants                   { v :: rest }
  | v = enum_variant; rest = enum_variants_no_leading_comma         { v :: rest }

enum_variant:
  | n = IDENT                                    { { v_name = n; v_payload = [] } }
  | n = IDENT; LPAREN; ps = params; RPAREN       { { v_name = n; v_payload = ps } }

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
  | FN; n = IDENT; LPAREN; ps = params; RPAREN; r = ret_opt; raises_opt; b = block
    { { im_name = n; im_params = ps; im_ret = r; im_body = b } }

type_name:
  | t = IDENT                                    { t }
  | t = IDENT; QMARK                             { t ^ "?" }

ret_opt:
  |                       { None }
  | ARROW; t = type_name  { Some t }

raises_opt:
  |                                              { () }
  | RAISES; LBRACE; xs = ident_list; RBRACE      { ignore xs }

requires_opt:
  |                                              { [] }
  | REQUIRES; LBRACE; xs = ident_list; RBRACE    { xs }

ident_list:
  |                                              { [] }
  | x = IDENT                                    { [x] }
  | x = IDENT; COMMA; rest = ident_list          { x :: rest }

cap_method:
  | FN; n = IDENT; LPAREN; ps = params; RPAREN; r = ret_opt; raises_opt
    { { m_name = n; m_params = ps; m_ret = r } }

params:
  |                                                 { [] }
  | p = param                                       { [p] }
  | p = param; COMMA; rest = params                 { p :: rest }

param:
  | n = IDENT; COLON; t = type_name                 { (n, t) }

block:
  (* Every surface `{ ... }` becomes a `Scope`, which is the defer-frame
     boundary (DEC-012). The inner `block_of_items` lowers to `Let` / `Block`
     for sequencing only — those do not push frames. *)
  | LBRACE; items = list(block_item); RBRACE        { Scope (block_of_items items) }

block_item:
  | LET; m = mut_opt; n = IDENT; EQ; e = expr       { BLet { name = n; mut = m; rhs = e } }
  | e = expr                                        { BExpr e }

mut_opt:
  |     { false }
  | MUT { true  }

expr:
  | RETURN; e = expr             { Return e }
  | DEFER;  e = expr             { Defer e }
  (* `raise X` and `raise X(args)` reuse the atom IDENT/Call shape (state 21
     conflict, resolved by shift) instead of introducing an extra optional
     production. Keeps the conflict count from rising past Stage 4's 3. *)
  | RAISE; e = atom
      { match e with
        | Var v -> Raise { variant = v; payload = [] }
        | Call { fn = Var v; args } -> Raise { variant = v; payload = args }
        | _ -> failwith "raise expects a variant: `raise X` or `raise X(args)`" }
  | l = expr; QMARK_QMARK; r = expr { NullCoalesce (l, r) }
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
  | a = atom; QMARK_DOT; m = IDENT                       { OptChain { recv = a; name = m } }
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
  | IF; c = expr; t = block; e = else_opt                { If { cond = c; then_ = t; else_ = e } }
  | TRY; b = expr; CATCH; LBRACE; arms = catch_arms; RBRACE
      { Try { body = b; arms } }
  (* §7.3 (provide @ Scope { ... }) / §7.4 (Wiring values, no `in`) — Stage 7 / Stage 9 *)
  | PROVIDE; LBRACE; es = provide_entries; RBRACE; IN; b = block
    { Provide { entries = es; scope = None; body = Some b } }

else_opt:
  |                                                       { None }
  | ELSE; b = block                                       { Some b }
  | ELSE; e = if_expr                                     { Some e }

if_expr:
  | IF; c = expr; t = block; e = else_opt                 { If { cond = c; then_ = t; else_ = e } }

catch_arms:
  |                                                       { [] }
  | a = catch_arm                                         { [a] }
  | a = catch_arm; COMMA; rest = catch_arms               { a :: rest }
  | a = catch_arm; rest = catch_arms_no_leading_comma     { a :: rest }

catch_arms_no_leading_comma:
  | a = catch_arm                                         { [a] }
  | a = catch_arm; COMMA; rest = catch_arms               { a :: rest }
  | a = catch_arm; rest = catch_arms_no_leading_comma     { a :: rest }

catch_arm:
  | p = pattern; ARROW; e = expr                          { (p, e) }

pattern:
  | n = IDENT
      { if n = "_" then PWild else PVariant { tag = n; sub = [] } }
  | n = IDENT; LPAREN; ps = pat_list; RPAREN
      { PVariant { tag = n; sub = ps } }

pat_list:
  |                                                       { [] }
  | p = pat_arg                                           { [p] }
  | p = pat_arg; COMMA; rest = pat_list                   { p :: rest }

pat_arg:
  | n = IDENT
      { if n = "_" then PWild else PVar n }

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
