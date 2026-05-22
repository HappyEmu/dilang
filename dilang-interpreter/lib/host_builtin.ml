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

let register (ctx : ctx) =
  Hashtbl.replace ctx.host_constructors "StdoutLogger"  stdout_logger;
  Hashtbl.replace ctx.host_constructors "StdoutGreeter" stdout_greeter
