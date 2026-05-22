type value =
  | VUnit
  | VBool of bool
  | VInt  of int64
  | VStr  of string

let to_display = function
  | VUnit   -> "()"
  | VBool b -> string_of_bool b
  | VInt  i -> Int64.to_string i
  | VStr  s -> s
