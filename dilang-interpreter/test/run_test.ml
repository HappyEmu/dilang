let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let len = in_channel_length ic in
       really_input_string ic len)

let stage_test ~name () =
  let di     = "stages/" ^ name ^ ".di" in
  let expect = "expect/" ^ name ^ ".txt" in
  let buf = Buffer.create 256 in
  Dilang.Driver.run_file_to_buffer di buf;
  let actual   = Buffer.contents buf in
  let expected = read_file expect in
  Alcotest.(check string) name expected actual

let () =
  Alcotest.run "dilang-stages"
    [ "stage1",
      [ Alcotest.test_case "01_arith" `Quick (stage_test ~name:"01_arith")
      ; Alcotest.test_case "01b_full" `Quick (stage_test ~name:"01b_full")
      ]
    ]
