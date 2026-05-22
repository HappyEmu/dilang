open Parser

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
  | "fn"    -> FN
  | "let"   -> LET
  | "mut"   -> MUT
  | "true"  -> BOOL true
  | "false" -> BOOL false
  | _       -> IDENT s

let lex_string buf =
  let b = Buffer.create 32 in
  let rec loop () =
    match%sedlex buf with
    | '"' -> STR (Buffer.contents b)
    | "\\n"  -> Buffer.add_char b '\n'; loop ()
    | "\\t"  -> Buffer.add_char b '\t'; loop ()
    | "\\r"  -> Buffer.add_char b '\r'; loop ()
    | "\\\"" -> Buffer.add_char b '"';  loop ()
    | "\\\\" -> Buffer.add_char b '\\'; loop ()
    | eof    -> raise (Lex_error "unterminated string literal")
    | any    ->
        Buffer.add_string b (Sedlexing.Utf8.lexeme buf);
        loop ()
    | _ -> raise (Lex_error "unexpected character in string literal")
  in
  loop ()

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
  | eof    -> EOF
  | _      ->
      let s = Sedlexing.Utf8.lexeme buf in
      raise (Lex_error ("unexpected character: " ^ s))
