(* Small Stdlib.String-only helpers for Stage 9 string methods. No `Str`
   regex, no extra deps. *)

(* Index of the first occurrence of [sep] in [s] at or after [from], or None.
   Precondition: [sep <> ""]. *)
let find_from s sep from =
  let sl = String.length s and pl = String.length sep in
  let rec scan i =
    if i + pl > sl then None
    else if String.sub s i pl = sep then Some i
    else scan (i + 1)
  in
  scan from

(* Does [s] contain [needle] as a substring? An empty needle is contained
   in everything. *)
let contains s needle =
  String.length needle = 0 || find_from s needle 0 <> None

(* Split [s] on every occurrence of the multi-character separator [sep].
   Precondition: [sep <> ""] (the caller rejects the empty separator). *)
let split_on_substring s sep =
  let pl = String.length sep in
  let rec go start acc =
    match find_from s sep start with
    | Some i -> go (i + pl) (String.sub s start (i - start) :: acc)
    | None   -> List.rev (String.sub s start (String.length s - start) :: acc)
  in
  go 0 []
