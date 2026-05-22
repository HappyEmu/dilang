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
  List.iter (function
    | Ast.DFn f  -> Hashtbl.replace fns f.name f
    | Ast.DCap c -> Hashtbl.replace caps c.c_name c
  ) prog;
  fns, caps

let run_program ?(sink = Value.OutChan stdout) prog =
  let fns, cap_decls = build_tables prog in
  let main =
    match Hashtbl.find_opt fns "main" with
    | Some f -> f
    | None   -> failwith "no `main` function defined"
  in
  let host_constructors = Hashtbl.create 8 in
  let ctx : Value.ctx = {
    env  = Env.empty;
    fns;
    sink;
    caps = [];
    cap_decls;
    host_constructors;
  } in
  Host_builtin.register ctx;
  ignore (Eval.call_fn ctx main [])

let run_file ?(sink = Value.OutChan stdout) path =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun _sw ->
  let prog = parse_file path in
  run_program ~sink prog

let run_file_to_buffer path buf =
  run_file ~sink:(Value.Buf buf) path

let run_string_to_buffer src buf =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun _sw ->
  let prog = parse_string src in
  run_program ~sink:(Value.Buf buf) prog
