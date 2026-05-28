(* Stage 11: a minimal hand-rolled HTTP/1.1 codec shared by the blocking server
   and client host impls (`host_builtin.ml`). Deliberately tiny — no chunked
   encoding, no keep-alive (every message sets `Connection: close`), headers are
   parsed only far enough to find `Content-Length`. This is v0 plumbing, not a
   conformant HTTP stack; richer handling waits for a real stdlib. *)

let reason_phrase = function
  | 200 -> "OK"
  | 201 -> "Created"
  | 204 -> "No Content"
  | 400 -> "Bad Request"
  | 404 -> "Not Found"
  | 500 -> "Internal Server Error"
  | _   -> "Status"

(* Read header lines until the blank line; return the Content-Length if present
   (case-insensitive header name). *)
let read_headers r =
  let content_length = ref None in
  let rec loop () =
    match Eio.Buf_read.line r with
    | "" -> ()
    | line ->
        (match String.index_opt line ':' with
         | Some i ->
             let name = String.sub line 0 i |> String.trim |> String.lowercase_ascii in
             let value = String.sub line (i + 1) (String.length line - i - 1) |> String.trim in
             if name = "content-length" then
               content_length := int_of_string_opt value
         | None -> ());
        loop ()
  in
  loop ();
  !content_length

(* Server side: parse `METHOD PATH HTTP/1.1` + headers + body. A request with no
   Content-Length has no body — we must NOT read-to-EOF here, since the client
   holds the connection open waiting for our response (reading to EOF would
   deadlock). *)
let read_request r =
  let request_line = Eio.Buf_read.line r in
  let meth, path =
    match String.split_on_char ' ' request_line with
    | meth :: path :: _ -> meth, path
    | _ -> failwith ("malformed HTTP request line: " ^ request_line)
  in
  let body =
    match read_headers r with
    | Some n when n > 0 -> Eio.Buf_read.take n r
    | _                 -> ""
  in
  (meth, path, body)

(* Client side: parse `HTTP/1.1 CODE REASON` + headers + body. *)
let read_response r =
  let status_line = Eio.Buf_read.line r in
  let status =
    match String.split_on_char ' ' status_line with
    | _ :: code :: _ ->
        (match int_of_string_opt code with
         | Some n -> n
         | None   -> failwith ("malformed HTTP status line: " ^ status_line))
    | _ -> failwith ("malformed HTTP status line: " ^ status_line)
  in
  (* A response is delimited by Content-Length when present, otherwise by the
     peer closing the connection (`Connection: close`), so read-to-EOF is the
     correct fallback here (unlike a request). *)
  let body =
    match read_headers r with
    | Some n when n > 0 -> Eio.Buf_read.take n r
    | Some _            -> ""
    | None              -> Eio.Buf_read.take_all r
  in
  (status, body)

let write_response w ~status ~body =
  Eio.Buf_write.string w
    (Printf.sprintf
       "HTTP/1.1 %d %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
       status (reason_phrase status) (String.length body) body)

let write_request w ~meth ~host ~path ~body =
  Eio.Buf_write.string w
    (Printf.sprintf
       "%s %s HTTP/1.1\r\nHost: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
       meth path host (String.length body) body)
