let usage () =
  prerr_endline "usage: dilang run <file.di> [--max-requests N]";
  exit 64

(* Stage 11: `--max-requests N` bounds the HttpServer accept loop (interpreter
   plumbing only — never exposed to user code). Parse it from anywhere in the
   args after `run`; the remaining lone positional is the file path. *)
let parse_run_args args =
  let rec loop path max_requests = function
    | [] -> (path, max_requests)
    | "--max-requests" :: n :: rest ->
        (match int_of_string_opt n with
         | Some n -> loop path (Some n) rest
         | None   -> usage ())
    | arg :: rest ->
        (match path with
         | None   -> loop (Some arg) max_requests rest
         | Some _ -> usage ())
  in
  loop None None args

let () =
  match Array.to_list Sys.argv with
  | _ :: "run" :: rest ->
      let path, max_requests = parse_run_args rest in
      let path = match path with Some p -> p | None -> usage () in
      (try Dilang.Driver.run_file ?max_requests path
       with
       | Failure msg ->
           prerr_endline ("error: " ^ msg);
           exit 1
       | Dilang.Lexer.Lex_error msg ->
           prerr_endline ("lex error: " ^ msg);
           exit 1)
  | _ -> usage ()
