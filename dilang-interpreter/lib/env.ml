type t = Value.env

let empty : t = { values = [] }

let extend (env : t) name v ~mut : t =
  { values = (name, ref v, mut) :: env.values }

let lookup (env : t) name =
  match List.find_opt (fun (n, _, _) -> n = name) env.values with
  | Some (_, r, _) -> !r
  | None           -> failwith ("unbound name: " ^ name)

let find_ref (env : t) name =
  match List.find_opt (fun (n, _, _) -> n = name) env.values with
  | Some (_, r, mut) -> Some (r, mut)
  | None             -> None
