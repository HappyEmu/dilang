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

let build_fn_table prog =
  let tbl = Hashtbl.create 16 in
  List.iter (function
    | Ast.DFn f -> Hashtbl.replace tbl f.name f
  ) prog;
  tbl

let run_program ?(sink = Eval.OutChan stdout) prog =
  let fns = build_fn_table prog in
  let main =
    match Hashtbl.find_opt fns "main" with
    | Some f -> f
    | None   -> failwith "no `main` function defined"
  in
  let ctx : Eval.ctx = { env = Env.empty; fns; sink } in
  ignore (Eval.call_fn ctx main [])

let run_file ?(sink = Eval.OutChan stdout) path =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun _sw ->
  let prog = parse_file path in
  run_program ~sink prog

let run_file_to_buffer path buf =
  run_file ~sink:(Eval.Buf buf) path
