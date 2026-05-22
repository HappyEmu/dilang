let usage () =
  prerr_endline "usage: dilang run <file.di>";
  exit 64

let () =
  match Array.to_list Sys.argv with
  | _ :: "run" :: [path] ->
      (try Dilang.Driver.run_file path
       with
       | Failure msg ->
           prerr_endline ("error: " ^ msg);
           exit 1
       | Dilang.Lexer.Lex_error msg ->
           prerr_endline ("lex error: " ^ msg);
           exit 1)
  | _ -> usage ()
