type t = Value.env

let empty : t = { values = [] }

let extend (env : t) name v : t =
  { values = (name, ref v) :: env.values }

let lookup (env : t) name =
  match List.assoc_opt name env.values with
  | Some r -> !r
  | None   -> failwith ("unbound name: " ^ name)
