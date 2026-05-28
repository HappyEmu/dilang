%{
open Ast
%}

%token <int64>  INT
%token <string> STR
%token <Ast.string_part list> STR_INTERP
%token <bool>   BOOL
%token <string> IDENT
%token <string> LIFETIME
%token FN LET MUT RETURN
%token CAPABILITY WITH SCOPE UNDER REQUIRES RAISES IN
%token STRUCT IMPL FOR EXTENDS
%token IF ELSE ENUM RAISE TRY CATCH DEFER
%token LOOP WHILE BREAK CONTINUE
%token PLUS MINUS STAR SLASH
%token EQ EQEQ BANGEQ LT GT LEQ GEQ
%token LARROW ELLIPSIS
%token LPAREN RPAREN LBRACE RBRACE
%token LBRACKET RBRACKET
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
  | FN; n = IDENT; LPAREN; ps = params; RPAREN;
    r = ret_opt; raises_opt; req = requires_opt; EQ; b = expr
    { DFn { name = n; params = ps; ret = r; requires = req; body = b } }
  | CAPABILITY; n = IDENT; sc = cap_scope_opt; ext = extends_opt; LBRACE; ms = list(cap_method); RBRACE
    { DCap { c_name = n; c_scope = sc; c_extends = ext; c_methods = ms } }
  | SCOPE; n = lifetime; p = scope_parent_opt
    { DScope { sc_name = n; sc_parent = p } }
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

cap_scope_opt:
  |                                              { None }
  | AT; sc = lifetime                            { Some sc }

scope_parent_opt:
  |                                              { None }
  | UNDER; p = lifetime                          { Some p }

lifetime:
  | s = LIFETIME                                 { s }

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
  | WHILE; c = head_expr; b = block                 { BExpr (While { cond = c; body = b }) }
  (* Stage 8 (D2): `for` is statement-only, parallels `while`. Loop var is
     bound `~mut:false` per iteration. DEC-013: yields `VUnit`. The iter
     uses `head_expr` (no toplevel `IDENT { ... }` struct-lit form), so
     `for n in nums { ... }` parses with `nums` as a bare `Var`. *)
  | FOR; n = IDENT; IN; e = head_expr; b = block
      { BExpr (For { var = n; iter = e; body = b }) }
  | BREAK; p = break_payload_opt                    { BExpr (Break p) }
  | CONTINUE                                        { BExpr Continue }
  (* Assignment piggybacks on `expr` so we don't have to redeclare every
     IDENT-prefixed atom production. The semantic action pattern-matches the
     LHS: bare `Var` → `Assign`, `FieldGet` → `AssignField`, `Index` →
     `AssignIndex` (Stage 8); anything else is a parse-time error. EQ
     cannot occur inside `expr`, so the optional tail does not add new
     conflicts. *)
  | lhs = expr; t = assign_tail
      { match t with
        | None     -> BExpr lhs
        | Some rhs ->
            (match lhs with
             | Var n -> BExpr (Assign { name = n; rhs })
             | FieldGet { recv; name } ->
                 BExpr (AssignField { recv; name; rhs })
             | Index { target; idx } ->
                 BExpr (AssignIndex { target; idx; rhs })
             | _ ->
                 failwith
                   "left-hand side of `=` must be `name`, `expr.field`, or `expr[i]`") }

assign_tail:
  |               { None }
  | EQ; e = expr  { Some e }

(* DEC-013: `break;` carries no value (yields VUnit); `break v` carries one.
   Same trick Stage 5 used for `raise` — parse `BREAK atom?` explicitly via a
   dedicated option rule so we don't reintroduce the optional-prefix
   conflict path. Conflict watch: `BREAK . <atom-token>` shifts greedily,
   which matches DEC-013 semantics. *)
break_payload_opt:
  |              { None }
  | a = atom     { Some a }

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
  (* Stage 8 (D1): unify dotted-call into a single arbitrary-atom form.
     Eval routes capability vs value-method dispatch — see [[dec-001]] and
     the `MethodCall` arm in eval.ml. `dot_tail` distinguishes a method call
     (`Some args`) from a plain field access (`None`). *)
  | a = atom; DOT; m = IDENT; t = dot_tail
      { match t with
        | None      -> FieldGet { recv = a; name = m }
        | Some args -> MethodCall { target = a; name = m; args } }
  | n = IDENT; LBRACE; fs = struct_lit_fields; RBRACE
      { StructLit { ty = n; fields = fs } }
  | n = IDENT                                            { Var n }
  | n = IDENT; LPAREN; args = arglist; RPAREN            { Call { fn = Var n; args } }
  (* Stage 8: `[a, b, c]` array literal and `a[i]` indexed read. The
     `atom LBRACKET` form is left-recursive; default shift on LBRACKET wins,
     resolving `[1,2,3][0]` and `xs[0][1]` correctly. *)
  | LBRACKET; xs = arglist; RBRACKET                     { ArrayLit xs }
  | a = atom; LBRACKET; i = expr; RBRACKET               { Index { target = a; idx = i } }
  | LPAREN; e = expr; RPAREN                             { e }
  | b = block                                            { b }
  | IF; c = head_expr; t = block; e = else_opt           { If { cond = c; then_ = t; else_ = e } }
  (* DEC-013: `loop` is an expression yielding `break v`'s payload (VUnit if
     `break;` carries nothing). `while` lives at block_item only. *)
  | LOOP; b = block                                       { Loop b }
  | TRY; b = expr; CATCH; LBRACE; arms = catch_arms; RBRACE
      { Try { body = b; arms } }
  (* RFC-001 scoped wiring. Wiring values and spreads parse here, but remain
     Stage-9 runtime work. *)
  | w = with_caps_expr                                      { w }

(* Stage 8: Rust-style restricted expression — used in the head position of
   `if` / `while` / `for ... in` (and `else if`) where a trailing `LBRACE`
   must be the body of the construct, not the start of a struct literal.
   `head_atom` mirrors `atom` but drops the `IDENT LBRACE fields RBRACE`
   form; `head_expr` mirrors `expr` but uses `head_atom` recursively.
   StructLit is still reachable inside parens: `for n in (S { x: 1 }) { ... }`. *)
head_expr:
  | RETURN; e = expr                  { Return e }
  | DEFER;  e = expr                  { Defer e }
  | RAISE; e = atom
      { match e with
        | Var v -> Raise { variant = v; payload = [] }
        | Call { fn = Var v; args } -> Raise { variant = v; payload = args }
        | _ -> failwith "raise expects a variant: `raise X` or `raise X(args)`" }
  | l = head_expr; QMARK_QMARK; r = head_expr { NullCoalesce (l, r) }
  | l = head_expr; PLUS;   r = head_expr   { BinOp (Add, l, r) }
  | l = head_expr; MINUS;  r = head_expr   { BinOp (Sub, l, r) }
  | l = head_expr; STAR;   r = head_expr   { BinOp (Mul, l, r) }
  | l = head_expr; SLASH;  r = head_expr   { BinOp (Div, l, r) }
  | l = head_expr; EQEQ;   r = head_expr   { BinOp (Eq,  l, r) }
  | l = head_expr; BANGEQ; r = head_expr   { BinOp (Neq, l, r) }
  | l = head_expr; LT;     r = head_expr   { BinOp (Lt,  l, r) }
  | l = head_expr; GT;     r = head_expr   { BinOp (Gt,  l, r) }
  | l = head_expr; LEQ;    r = head_expr   { BinOp (Leq, l, r) }
  | l = head_expr; GEQ;    r = head_expr   { BinOp (Geq, l, r) }
  | a = head_atom                     { a }

head_atom:
  | i = INT                                                  { Lit (LInt i) }
  | s = STR                                                  { Lit (LStr s) }
  | parts = STR_INTERP                                       { StringInterp parts }
  | b = BOOL                                                 { Lit (LBool b) }
  | a = head_atom; QMARK_DOT; m = IDENT                      { OptChain { recv = a; name = m } }
  | a = head_atom; DOT; m = IDENT; t = dot_tail
      { match t with
        | None      -> FieldGet { recv = a; name = m }
        | Some args -> MethodCall { target = a; name = m; args } }
  | n = IDENT                                                { Var n }
  | n = IDENT; LPAREN; args = arglist; RPAREN                { Call { fn = Var n; args } }
  | LBRACKET; xs = arglist; RBRACKET                         { ArrayLit xs }
  | a = head_atom; LBRACKET; i = expr; RBRACKET              { Index { target = a; idx = i } }
  | LPAREN; e = expr; RPAREN                                 { e }
  | b = block                                                { b }
  | IF; c = head_expr; t = block; e = else_opt               { If { cond = c; then_ = t; else_ = e } }
  | LOOP; b = block                                          { Loop b }
  | TRY; b = expr; CATCH; LBRACE; arms = catch_arms; RBRACE  { Try { body = b; arms } }
  | w = with_caps_expr                                      { w }

else_opt:
  |                                                       { None }
  | ELSE; b = block                                       { Some b }
  | ELSE; e = if_expr                                     { Some e }

if_expr:
  | IF; c = head_expr; t = block; e = else_opt            { If { cond = c; then_ = t; else_ = e } }

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

with_caps_expr:
  | WITH; LBRACKET; es = with_entries; RBRACKET; sc = with_scope_opt; b = with_body_opt
    { WithCaps { entries = es; scope = sc; body = b } }

with_scope_opt:
  |                                                       { None }
  | AT; sc = lifetime                                    { Some sc }

with_body_opt:
  |                                                       { None }
  | b = block                                             { Some b }

with_entries:
  |                                                       { [] }
  | e = with_entry                                        { [e] }
  | e = with_entry; COMMA; rest = with_entries            { e :: rest }
  | e = with_entry; rest = with_entries_no_leading_comma  { e :: rest }

with_entries_no_leading_comma:
  | e = with_entry                                        { [e] }
  | e = with_entry; COMMA; rest = with_entries            { e :: rest }
  | e = with_entry; rest = with_entries_no_leading_comma  { e :: rest }

with_entry:
  | cap = IDENT; LARROW; rhs = expr; sc = binding_scope_opt
    { Binding { cap; rhs; scope = sc } }
  | ELLIPSIS; e = expr
    { Spread e }

binding_scope_opt:
  |                                                       { None }
  | AT; sc = lifetime                                    { Some sc }

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
