open Value

let reject_fields ty fs =
  match fs with
  | [] -> ()
  | (fname, _) :: _ -> failwith ("host impl " ^ ty ^ " has no field " ^ fname)

let stdout_logger fs : impl_value =
  reject_fields "StdoutLogger" fs;
  {
    ty      = "StdoutLogger";
    fields  = [];
    cap_env = [];
    methods = [
      "info", DHost (fun ctx -> function
        | [VStr s] -> emit_line ctx.sink s; VUnit
        | _ -> failwith "Logger.info expects (Str)");
      "warn", DHost (fun ctx -> function
        | [VStr s] -> emit_line ctx.sink ("WARN: " ^ s); VUnit
        | _ -> failwith "Logger.warn expects (Str)");
    ];
  }

let stdout_greeter fs : impl_value =
  reject_fields "StdoutGreeter" fs;
  {
    ty      = "StdoutGreeter";
    fields  = [];
    cap_env = [];
    methods = [
      "hello", DHost (fun ctx -> function
        | [VStr s] -> emit_line ctx.sink ("hi, " ^ s); VUnit
        | _ -> failwith "Greeter.hello expects (Str)");
    ];
  }

(* Register `Option<T>` as a stdlib enum. Type parameter `T` is recorded but
   not enforced — the interpreter is monomorphic. Some/None reach the AST via
   the same path as user variants (Call/Var → variants), so no parser special
   case is needed. *)
let register_enums (ctx : ctx) =
  let option_enum : Ast.enum_decl = {
    e_name = "Option";
    e_params = ["T"];
    e_variants = [
      { v_name = "Some"; v_payload = [("value", "T")] };
      { v_name = "None"; v_payload = [] };
    ];
  } in
  Hashtbl.replace ctx.enum_decls "Option" option_enum;
  List.iter (fun (v : Ast.enum_variant) ->
    Hashtbl.replace ctx.variants v.v_name ("Option", v)
  ) option_enum.e_variants

let register (ctx : ctx) =
  Hashtbl.replace ctx.host_constructors "StdoutLogger"  stdout_logger;
  Hashtbl.replace ctx.host_constructors "StdoutGreeter" stdout_greeter;
  register_enums ctx
