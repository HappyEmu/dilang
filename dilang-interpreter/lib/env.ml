type t = {
  values : (Ast.ident * Value.value ref) list;
}

let empty = { values = [] }

let extend env name v =
  { values = (name, ref v) :: env.values }

let lookup env name =
  match List.assoc_opt name env.values with
  | Some r -> !r
  | None   -> failwith ("unbound name: " ^ name)
