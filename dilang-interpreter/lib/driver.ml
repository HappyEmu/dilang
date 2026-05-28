let parse_lexbuf buf =
  let provider () =
    let tok = Lexer.token buf in
    let start, stop = Sedlexing.lexing_positions buf in
    (tok, start, stop)
  in
  let parse =
    MenhirLib.Convert.Simplified.traditional2revised Parser.program
  in
  parse provider

let parse_string src =
  parse_lexbuf (Sedlexing.Utf8.from_string src)

let parse_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let len = in_channel_length ic in
       let src = really_input_string ic len in
       parse_string src)

let build_tables prog =
  let fns = Hashtbl.create 16 in
  let caps = Hashtbl.create 8 in
  let structs = Hashtbl.create 8 in
  let impls_by_ty : (Ast.ident, Ast.impl_decl list) Hashtbl.t = Hashtbl.create 8 in
  let enums : (Ast.type_name, Ast.enum_decl) Hashtbl.t = Hashtbl.create 8 in
  List.iter (function
    | Ast.DFn f     -> Hashtbl.replace fns f.name f
    | Ast.DCap c    -> Hashtbl.replace caps c.c_name c
    | Ast.DStruct s -> Hashtbl.replace structs s.s_name s
    | Ast.DImpl i   ->
        let prev = try Hashtbl.find impls_by_ty i.for_ty with Not_found -> [] in
        Hashtbl.replace impls_by_ty i.for_ty (i :: prev)
    | Ast.DEnum e   -> Hashtbl.replace enums e.e_name e
  ) prog;
  fns, caps, structs, impls_by_ty, enums

(* BFS closure of the `extends` relation, including the cap itself. *)
let compute_ext_of (cap_decls : (Ast.ident, Ast.cap_decl) Hashtbl.t)
  : (Ast.ident, Ast.ident list) Hashtbl.t =
  let ext_of = Hashtbl.create 16 in
  Hashtbl.iter (fun name _ ->
    let seen = Hashtbl.create 4 in
    let order = ref [] in
    let rec visit chain c =
      if List.mem c chain then
        failwith ("capability extends cycle involving " ^ c)
      else if Hashtbl.mem seen c then ()
      else begin
        Hashtbl.add seen c ();
        order := c :: !order;
        match Hashtbl.find_opt cap_decls c with
        | None -> failwith ("unknown capability in extends: " ^ c)
        | Some d -> List.iter (visit (c :: chain)) d.c_extends
      end
    in
    visit [] name;
    Hashtbl.replace ext_of name (List.rev !order)
  ) cap_decls;
  ext_of

(* For struct `ty`, collect every (method_name, impl_method) from all
   `impl ... for ty` blocks. Panic on duplicate method names. *)
let methods_for_ty impls_by_ty (ty : Ast.ident)
  : (Ast.ident * Ast.impl_method) list =
  let impls = try Hashtbl.find impls_by_ty ty with Not_found -> [] in
  let acc = ref [] in
  List.iter (fun (i : Ast.impl_decl) ->
    List.iter (fun (m : Ast.impl_method) ->
      if List.mem_assoc m.im_name !acc then
        failwith ("duplicate method " ^ m.im_name ^ " on struct " ^ ty);
      acc := (m.im_name, m) :: !acc
    ) i.methods
  ) impls;
  List.rev !acc

let make_user_constructor (s : Ast.struct_decl) methods
  : (Ast.ident * Value.value) list -> Value.impl_value =
  fun args ->
    (* Reject unknown fields. *)
    List.iter (fun (fname, _) ->
      if not (List.mem_assoc fname s.s_fields) then
        failwith (Printf.sprintf "struct %s has no field %s" s.s_name fname)
    ) args;
    (* Look up each declared field; reject duplicates and missing fields. *)
    let fields =
      List.map (fun (fname, _ty) ->
        match List.filter (fun (n, _) -> n = fname) args with
        | []        -> failwith (Printf.sprintf "struct %s is missing field %s" s.s_name fname)
        | [(_, v)]  -> (fname, ref v)
        | _         -> failwith (Printf.sprintf "struct %s: field %s given more than once" s.s_name fname)
      ) s.s_fields
    in
    let dispatch =
      List.map (fun (mname, m) -> (mname, Value.DUser m)) methods
    in
    { Value.ty = s.s_name; methods = dispatch; fields; cap_env = [] }

let format_payload (vs : Value.value list) =
  match vs with
  | [] -> ""
  | _  -> "(" ^ String.concat ", " (List.map Value.to_display vs) ^ ")"

let run_program ?(sink = Value.OutChan stdout) ?max_requests ~net prog =
  (* Stage 11 (DEC-018): prepend the parsed stdlib prelude — capability
     interfaces (HttpServer/HttpClient), data structs (Request/Response), and
     the HttpError enum — ahead of the user program. It is ordinary dilang
     source parsed by the same path; `build_tables` sees one flat decl list, so
     the prelude decls land in the same tables as user decls. A temporary
     stopgap until a module system + stdlib exist. *)
  let prelude = parse_string Prelude.source in
  let prog = prelude @ prog in
  let fns, cap_decls, struct_decls, impls_by_ty, user_enums = build_tables prog in
  let main =
    match Hashtbl.find_opt fns "main" with
    | Some f -> f
    | None   -> failwith "no `main` function defined"
  in
  let host_constructors = Hashtbl.create 8 in
  let ext_of = compute_ext_of cap_decls in
  let user_constructors = Hashtbl.create 8 in
  Hashtbl.iter (fun ty s ->
    let methods = methods_for_ty impls_by_ty ty in
    Hashtbl.replace user_constructors ty (make_user_constructor s methods)
  ) struct_decls;
  let enum_decls = Hashtbl.create 8 in
  let variants = Hashtbl.create 16 in
  let ctx : Value.ctx = {
    env  = Env.empty;
    fns;
    sink;
    net;
    max_requests;
    caps = [];
    cap_decls;
    host_constructors;
    struct_decls;
    user_constructors;
    ext_of;
    enum_decls;
    variants;
    defers = ref [];
  } in
  (* Host stdlib first — registers Option<T> with Some/None in variants. Any
     user enum re-declaring Some/None is rejected below as a duplicate. *)
  Host_builtin.register ctx;
  Hashtbl.iter (fun enum_name (decl : Ast.enum_decl) ->
    if enum_name = "Option" then
      failwith "enum Option is reserved by the host stdlib"
    else begin
      Hashtbl.replace ctx.enum_decls enum_name decl;
      List.iter (fun (v : Ast.enum_variant) ->
        match Hashtbl.find_opt ctx.variants v.v_name with
        | Some (other_enum, _) ->
            failwith (Printf.sprintf
              "duplicate variant tag: %s (also defined in enum %s)"
              v.v_name other_enum)
        | None ->
            Hashtbl.replace ctx.variants v.v_name (enum_name, v)
      ) decl.e_variants
    end
  ) user_enums;
  try ignore (Eval.call_fn ctx main [])
  with Eval.Dilang_error { tag; payload } ->
    failwith ("uncaught raise: " ^ tag ^ format_payload payload)

let run_file ?(sink = Value.OutChan stdout) ?max_requests path =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun _sw ->
  let net = (Eio.Stdenv.net env :> [`Generic] Eio.Net.ty Eio.Resource.t) in
  let prog = parse_file path in
  run_program ~sink ?max_requests ~net prog

let run_file_to_buffer path buf =
  run_file ~sink:(Value.Buf buf) path

let run_string_to_buffer src buf =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun _sw ->
  let net = (Eio.Stdenv.net env :> [`Generic] Eio.Net.ty Eio.Resource.t) in
  let prog = parse_string src in
  run_program ~sink:(Value.Buf buf) ~net prog
