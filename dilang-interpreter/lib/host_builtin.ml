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

(* Stage 11 host impls. Both are fieldless `impl_value`s whose methods are
   `DHost` OCaml functions; dispatch reaches them by LHS cap name through
   `ext_of` (see `cap_call` in eval.ml), so no `impl ... for` decl is needed.
   The dilang-level capability/struct/enum *declarations* live in the parsed
   prelude (`prelude.ml`); only these impls stay in OCaml. *)

(* The per-`with` switch the capability was bound under. `serve`/`connect`
   attach their sockets to it, so they live exactly as long as the `with`
   block that wired the capability. *)
let cap_switch ctx =
  match ctx.caps with
  | frame :: _ -> frame.switch
  | []         -> failwith "no capability scope active (internal error)"

let build_request ctx ~meth ~path ~body =
  (Hashtbl.find ctx.user_constructors "Request")
    [ ("method", VStr meth); ("path", VStr path); ("body", VStr body) ]

let build_response ctx ~status ~body =
  (Hashtbl.find ctx.user_constructors "Response")
    [ ("status", VInt (Int64.of_int status)); ("body", VStr body) ]

let response_fields iv =
  let field name =
    match List.assoc_opt name iv.fields with
    | Some r -> !r
    | None   -> failwith ("Response is missing field " ^ name)
  in
  let status =
    match field "status" with
    | VInt n -> Int64.to_int n
    | _      -> failwith "Response.status must be I64"
  in
  let body =
    match field "body" with
    | VStr s -> s
    | _      -> failwith "Response.body must be Str"
  in
  (status, body)

let blocking_http_server fs : impl_value =
  reject_fields "BlockingHttpServer" fs;
  {
    ty      = "BlockingHttpServer";
    fields  = [];
    cap_env = [];
    methods = [
      "serve", DHost (fun ctx -> function
        | [VInt port; (VClosure _ | VFn _ as handler)] ->
            let sw  = cap_switch ctx in
            let net = ctx.net in
            let port = Int64.to_int port in
            let sock =
              Eio.Net.listen ~sw ~backlog:5 ~reuse_addr:true net
                (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
            in
            let handle_conn flow =
              let r = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
              let (meth, path, body) = Http_codec.read_request r in
              let request = build_request ctx ~meth ~path ~body in
              (* The load-bearing call: `call_value` swaps in the handler
                 closure's *captured* caps, so `Logger.info` inside the handler
                 resolves even though we are calling from OCaml host code,
                 outside the `with` block. *)
              match Eval.call_value ctx handler [VImpl request] with
              | VImpl iv ->
                  let (status, rbody) = response_fields iv in
                  Eio.Buf_write.with_flow flow (fun w ->
                    Http_codec.write_response w ~status ~body:rbody)
              | _ -> failwith "HttpServer handler did not return a Response"
            in
            (* Per-connection switch closes the accepted flow on completion. *)
            let serve_one () =
              Eio.Switch.run (fun conn_sw ->
                let flow, _addr = Eio.Net.accept ~sw:conn_sw sock in
                handle_conn flow)
            in
            (match ctx.max_requests with
             | Some n -> for _ = 1 to n do serve_one () done
             | None   -> while true do serve_one () done);
            VUnit
        | _ -> failwith "HttpServer.serve expects (I64, fn(Request) -> Response)");
    ];
  }

(* Parse `http://host[:port]/path`. Returns None for anything else (→ InvalidUrl). *)
let parse_url url =
  let prefix = "http://" in
  if not (String.starts_with ~prefix url) then None
  else
    let rest = String.sub url (String.length prefix)
                 (String.length url - String.length prefix) in
    let authority, path =
      match String.index_opt rest '/' with
      | Some i -> (String.sub rest 0 i, String.sub rest i (String.length rest - i))
      | None   -> (rest, "/")
    in
    if authority = "" then None
    else
      match String.index_opt authority ':' with
      | None -> Some (authority, 80, path)
      | Some i ->
          let host = String.sub authority 0 i in
          let pstr = String.sub authority (i + 1) (String.length authority - i - 1) in
          (match int_of_string_opt pstr with
           | Some port when host <> "" -> Some (host, port, path)
           | _ -> None)

let http_request ctx ~meth ~url ~body =
  let sw  = cap_switch ctx in
  let net = ctx.net in
  match parse_url url with
  | None -> raise (Eval.Dilang_error { tag = "InvalidUrl"; payload = [] })
  | Some (host, port, path) ->
      let addr =
        match
          (try Eio.Net.getaddrinfo_stream net host ~service:(string_of_int port)
           with _ -> [])
        with
        | a :: _ -> a
        | []     ->
            raise (Eval.Dilang_error
                     { tag = "ConnectionFailed";
                       payload = [VStr ("cannot resolve host " ^ host)] })
      in
      let flow =
        try Eio.Net.connect ~sw net addr
        with ex ->
          raise (Eval.Dilang_error
                   { tag = "ConnectionFailed";
                     payload = [VStr (Printexc.to_string ex)] })
      in
      let host_header = host ^ ":" ^ string_of_int port in
      Eio.Buf_write.with_flow flow (fun w ->
        Http_codec.write_request w ~meth ~host:host_header ~path ~body);
      let r = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
      let (status, rbody) = Http_codec.read_response r in
      (* DEC-019: v0 does not auto-raise BadStatus on status >= 400; the variant
         exists for callers/future use, but every response (any status) is
         returned as a `Response`. *)
      VImpl (build_response ctx ~status ~body:rbody)

let blocking_http_client fs : impl_value =
  reject_fields "BlockingHttpClient" fs;
  {
    ty      = "BlockingHttpClient";
    fields  = [];
    cap_env = [];
    methods = [
      "get", DHost (fun ctx -> function
        | [VStr url] -> http_request ctx ~meth:"GET" ~url ~body:""
        | _ -> failwith "HttpClient.get expects (Str)");
      "post", DHost (fun ctx -> function
        | [VStr url; VStr body] -> http_request ctx ~meth:"POST" ~url ~body
        | _ -> failwith "HttpClient.post expects (Str, Str)");
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
  Hashtbl.replace ctx.host_constructors "BlockingHttpServer" blocking_http_server;
  Hashtbl.replace ctx.host_constructors "BlockingHttpClient" blocking_http_client;
  register_enums ctx
