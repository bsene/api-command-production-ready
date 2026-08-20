(* Alcotest port of subtle.ConstantTimeCompare behaviour (L1d, T1). *)

open Apicommand.Constant_time

let equal_same () = Alcotest.(check bool) "equal strings are equal" true (equal "abc" "abc")
let equal_empty () = Alcotest.(check bool) "both empty are equal" true (equal "" "")
let equal_diff_len () = Alcotest.(check bool) "different lengths are not equal" false (equal "abc" "ab")
let equal_prefix () = Alcotest.(check bool) "prefix is not equal" false (equal "abc" "abcd")
let equal_diff_byte () = Alcotest.(check bool) "differing last byte" false (equal "abc" "abd")
let equal_first_byte () = Alcotest.(check bool) "differing first byte" false (equal "xbc" "abc")

let () =
  Alcotest.run "constant_time"
    [ ("equal",
       [ Alcotest.test_case "same" `Quick equal_same
       ; Alcotest.test_case "empty" `Quick equal_empty
       ; Alcotest.test_case "diff length" `Quick equal_diff_len
       ; Alcotest.test_case "prefix" `Quick equal_prefix
       ; Alcotest.test_case "diff last byte" `Quick equal_diff_byte
       ; Alcotest.test_case "diff first byte" `Quick equal_first_byte ])
    ]