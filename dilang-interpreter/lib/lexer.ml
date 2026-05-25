open Parser
open Ast

exception Lex_error of string

let digit       = [%sedlex.regexp? '0'..'9']
let int_lit     = [%sedlex.regexp? Plus digit]
let id_start    = [%sedlex.regexp? 'a'..'z' | 'A'..'Z' | '_']
let id_cont     = [%sedlex.regexp? id_start | digit]
let identifier  = [%sedlex.regexp? id_start, Star id_cont]
let line_break  = [%sedlex.regexp? '\n' | '\r' | "\r\n"]
let whitespace  = [%sedlex.regexp? Plus (' ' | '\t' | line_break)]
let line_comment = [%sedlex.regexp? "//", Star (Compl ('\n' | '\r'))]

let keyword_or_ident s =
  match s with
  | "fn"         -> FN
  | "let"        -> LET
  | "mut"        -> MUT
  | "return"     -> RETURN
  | "capability" -> CAPABILITY
  | "provide"    -> PROVIDE
  | "requires"   -> REQUIRES
  | "raises"     -> RAISES
  | "in"         -> IN
  | "struct"     -> STRUCT
  | "impl"       -> IMPL
  | "for"        -> FOR
  | "extends"    -> EXTENDS
  | "if"         -> IF
  | "else"       -> ELSE
  | "enum"       -> ENUM
  | "raise"      -> RAISE
  | "try"        -> TRY
  | "catch"      -> CATCH
  | "defer"      -> DEFER
  | "true"       -> BOOL true
  | "false"      -> BOOL false
  | _            -> IDENT s

(* Read the source of an interpolation expression from `buf`, starting just
   after the opening `${`. Balances braces, respects nested string literals,
   and stops at the matching `}` (which is consumed but not included in the
   returned source). *)
let capture_interp buf =
  let out = Buffer.create 64 in
  let depth = ref 1 in
  let rec normal () =
    match%sedlex buf with
    | '{' ->
        incr depth;
        Buffer.add_char out '{';
        normal ()
    | '}' ->
        decr depth;
        if !depth = 0 then ()
        else begin
          Buffer.add_char out '}';
          normal ()
        end
    | '"' ->
        Buffer.add_char out '"';
        in_string ()
    | '\\', any ->
        Buffer.add_string out (Sedlexing.Utf8.lexeme buf);
        normal ()
    | eof -> raise (Lex_error "unterminated interpolation")
    | any ->
        Buffer.add_string out (Sedlexing.Utf8.lexeme buf);
        normal ()
    | _ -> raise (Lex_error "unexpected character in interpolation")
  and in_string () =
    match%sedlex buf with
    | '\\', any ->
        Buffer.add_string out (Sedlexing.Utf8.lexeme buf);
        in_string ()
    | '"' ->
        Buffer.add_char out '"';
        normal ()
    | eof -> raise (Lex_error "unterminated string in interpolation")
    | any ->
        Buffer.add_string out (Sedlexing.Utf8.lexeme buf);
        in_string ()
    | _ -> raise (Lex_error "unexpected character in string in interpolation")
  in
  normal ();
  Buffer.contents out

let rec token buf =
  match%sedlex buf with
  | whitespace   -> token buf
  | line_comment -> token buf
  | int_lit      -> INT (Int64.of_string (Sedlexing.Utf8.lexeme buf))
  | '"'          -> lex_string buf
  | identifier   -> keyword_or_ident (Sedlexing.Utf8.lexeme buf)
  | "->"   -> ARROW
  | "=="   -> EQEQ
  | "!="   -> BANGEQ
  | "<="   -> LEQ
  | ">="   -> GEQ
  | "??"   -> QMARK_QMARK
  | "?."   -> QMARK_DOT
  | '?'    -> QMARK
  | '+'    -> PLUS
  | '-'    -> MINUS
  | '*'    -> STAR
  | '/'    -> SLASH
  | '='    -> EQ
  | '<'    -> LT
  | '>'    -> GT
  | '('    -> LPAREN
  | ')'    -> RPAREN
  | '{'    -> LBRACE
  | '}'    -> RBRACE
  | ','    -> COMMA
  | ':'    -> COLON
  | '@'    -> AT
  | '.'    -> DOT
  | eof    -> EOF
  | _      ->
      let s = Sedlexing.Utf8.lexeme buf in
      raise (Lex_error ("unexpected character: " ^ s))

and lex_string buf =
  let lit = Buffer.create 32 in
  let parts = ref [] in
  let any_interp = ref false in
  let flush_lit () =
    if Buffer.length lit > 0 then begin
      parts := SLit (Buffer.contents lit) :: !parts;
      Buffer.clear lit
    end
  in
  let rec loop () =
    match%sedlex buf with
    | '"'    -> flush_lit ()
    | "\\n"  -> Buffer.add_char lit '\n'; loop ()
    | "\\t"  -> Buffer.add_char lit '\t'; loop ()
    | "\\r"  -> Buffer.add_char lit '\r'; loop ()
    | "\\\"" -> Buffer.add_char lit '"';  loop ()
    | "\\\\" -> Buffer.add_char lit '\\'; loop ()
    | "\\${" -> Buffer.add_string lit "${"; loop ()
    | "${"   ->
        any_interp := true;
        flush_lit ();
        let src = capture_interp buf in
        let sub = Sedlexing.Utf8.from_string src in
        let provider () =
          let tok = token sub in
          let s, e = Sedlexing.lexing_positions sub in
          (tok, s, e)
        in
        let parse =
          MenhirLib.Convert.Simplified.traditional2revised Parser.expr_entry
        in
        let expr = parse provider in
        parts := SInterp expr :: !parts;
        loop ()
    | eof    -> raise (Lex_error "unterminated string literal")
    | any    ->
        Buffer.add_string lit (Sedlexing.Utf8.lexeme buf);
        loop ()
    | _      -> raise (Lex_error "unexpected character in string literal")
  in
  loop ();
  if !any_interp then STR_INTERP (List.rev !parts)
  else
    STR (match !parts with
         | [SLit s] -> s
         | []       -> ""
         | _        -> assert false)
