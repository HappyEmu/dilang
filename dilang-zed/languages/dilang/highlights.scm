; Highlight queries for Dilang.
;
; Captures use the names Zed recognises (see Zed's themes for the full set:
; @keyword, @function, @type, @variable, @string, @comment, @number, etc.).
; Order matters in tree-sitter queries: later, more specific captures win.

; -----------------------------------------------------------------------------
; Comments
; -----------------------------------------------------------------------------
(line_comment) @comment

; -----------------------------------------------------------------------------
; Literals
; -----------------------------------------------------------------------------
(string_literal) @string
(tagged_string_literal) @string
(string_interpolation
  "${" @punctuation.special
  "}"  @punctuation.special)
(escape_sequence) @string.escape

(number_literal) @number
(boolean_literal) @constant.builtin

; The leading `sql` in sql"..." is a string prefix, not a function call.
(tagged_string_literal
  tag: (identifier) @string.special)

; -----------------------------------------------------------------------------
; Keywords
; -----------------------------------------------------------------------------

; Declaration keywords
[
  "fn"
  "pub"
  "capability"
  "trait"
  "impl"
  "struct"
  "enum"
  "type"
  "scope"
  "test"
  "extends"
  "for"
  "under"
  "where"
] @keyword

; Effect/wiring keywords
[
  "requires"
  "raises"
  "with"
] @keyword

; Control-flow keywords
[
  "if"
  "else"
  "match"
  "loop"
  "while"
  "break"
  "return"
  "raise"
  "try"
  "catch"
  "defer"
  "select"
  "stream"
  "uncancellable"
] @keyword

; `continue` is a complete rule body (not part of a seq), so it doesn't surface
; as an anonymous node — match the rule instead.
(continue_expression) @keyword

; Binding keywords
[
  "let"
  "mut"
] @keyword

; -----------------------------------------------------------------------------
; Self
; -----------------------------------------------------------------------------
(self_expression) @variable.builtin
(self_type)       @type.builtin

; -----------------------------------------------------------------------------
; Function definitions
; -----------------------------------------------------------------------------
(function_definition
  name: (identifier) @function)

(method_signature
  name: (identifier) @function.method)

(method_with_default
  name: (identifier) @function.method)

(parameter
  name: (identifier) @variable.parameter)

(closure_parameter
  name: (identifier) @variable.parameter)

; -----------------------------------------------------------------------------
; Calls
; -----------------------------------------------------------------------------
(call_expression
  function: (identifier) @function.call)

(call_expression
  function: (field_access
    field: (identifier) @function.call))

(method_call
  method: (identifier) @function.method.call)

; Capability calls: `Logger.info(...)`. The receiver is a type-cased identifier.
(method_call
  receiver: (type_identifier) @type
  method: (identifier) @function.method.call)

; -----------------------------------------------------------------------------
; Types
; -----------------------------------------------------------------------------
(type_identifier) @type
(lifetime_identifier) @type

; Built-in primitive / stdlib types and the capabilities that ship with the
; runtime. These get a more specific capture than plain @type.
((type_identifier) @type.builtin
  (#match? @type.builtin "^(Str|Bool|I8|I16|I32|I64|U8|U16|U32|U64|F32|F64|Unit|Never|Uuid|Instant|Duration|Bytes|Json|Sql|Url|Email|Error|Map|List|Set|Option|Stream|Wiring|Rows|Page|Batch|Connection|Socket|Request|Response|Ordering|Mutex|Writer|Hasher|Group|SocketAddr|Signal|Token|ExitReason|StartupError|IoError|DbError|Timeout|Cancelled|ParseError|Process)$"))

((type_identifier) @type.builtin
  (#match? @type.builtin "^(IO|Logger|Clock|Database|ReadDb|WriteDb|IdGen|HttpClient|TokenSigner|Lifecycle|Drop|Iterator|Eq|Ord|Hash|Display|Clone)$"))

; -----------------------------------------------------------------------------
; Struct / enum literals & patterns
; -----------------------------------------------------------------------------
(struct_literal
  type: (type_identifier) @type)

(struct_field_init
  name: (identifier) @property)

(struct_field
  name: (identifier) @property)

(field_access
  field: (identifier) @property)

(map_entry
  key: (_) @property)

(variant_pattern
  name: (type_identifier) @constructor)

(enum_variant
  name: (type_identifier) @constructor)

; -----------------------------------------------------------------------------
; Wiring
; -----------------------------------------------------------------------------
(with_binding
  cap:   (type_identifier) @type)
(with_binding
  scope: (lifetime_identifier) @type)
(scope_annotation
  (lifetime_identifier) @type)

; -----------------------------------------------------------------------------
; Punctuation & operators
; -----------------------------------------------------------------------------
[
  "("
  ")"
  "{"
  "}"
  "["
  "]"
] @punctuation.bracket

[
  ","
  ";"
  ":"
  "."
] @punctuation.delimiter

[
  "->"
  "?."
  "?"
  "@"
  "..."
] @punctuation.special

[
  "+"
  "-"
  "*"
  "/"
  "%"
  "="
  "<-"
  "=="
  "!="
  "<"
  "<="
  ">"
  ">="
  "&&"
  "||"
  "!"
  "??"
] @operator

; -----------------------------------------------------------------------------
; Identifiers (fallback)
; -----------------------------------------------------------------------------
(identifier) @variable
