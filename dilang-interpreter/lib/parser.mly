%{
open Ast
%}

%token <int64>  INT
%token <string> STR
%token <bool>   BOOL
%token <string> IDENT
%token FN LET MUT
%token PLUS MINUS STAR SLASH
%token EQ EQEQ BANGEQ LT GT LEQ GEQ
%token LPAREN RPAREN LBRACE RBRACE
%token COMMA COLON ARROW
%token EOF

%left EQEQ BANGEQ LT GT LEQ GEQ
%left PLUS MINUS
%left STAR SLASH

%start <Ast.program> program

%%

program:
  | ds = list(decl); EOF { ds }

decl:
  | FN; n = IDENT; LPAREN; ps = params; RPAREN; r = ret_opt; b = block
    { DFn { name = n; params = ps; ret = r; body = b } }

ret_opt:
  |                       { None }
  | ARROW; t = IDENT      { Some t }

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
  | b = BOOL                                             { Lit (LBool b) }
  | n = IDENT                                            { Var n }
  | n = IDENT; LPAREN; args = arglist; RPAREN            { Call { fn = Var n; args } }
  | LPAREN; e = expr; RPAREN                             { e }
  | b = block                                            { b }

arglist:
  |                                                      { [] }
  | e = expr                                             { [e] }
  | e = expr; COMMA; rest = arglist                      { e :: rest }
