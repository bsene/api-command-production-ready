(* Alcotest port of the slog text-format substring assertions (L1c, T1).
   Mirrors orders_manager_test.go's captureLogger + Contains checks. *)

open Apicommand.Log

let contains s sub =
  let n = String.length s and m = String.length sub in
  let rec go i =
    if i + m > n then false
    else if String.sub s i m = sub then true else go (i + 1)
  in
  go 0

let check_sub name s sub =
  Alcotest.(check bool) name true (contains s sub)

let info_test () =
  let t = create () in
  info t "products request completed" [ "status", I 200; "product_count", I 4 ];
  let s = contents t in
  check_sub "INFO level" s "level=INFO";
  check_sub "message" s "products request completed";
  check_sub "status=200" s "status=200";
  check_sub "product_count=4" s "product_count=4"

let warn_test () =
  let t = create () in
  warn t "cart validation failed" [ "item_count", I 2; "invalid_count", I 2 ];
  let s = contents t in
  check_sub "WARN level" s "level=WARN";
  check_sub "message" s "cart validation failed";
  check_sub "invalid_count=2" s "invalid_count=2"

let error_test () =
  let t = create () in
  error t "requesting products failed" [ "url", S "https://products.com/products" ];
  let s = contents t in
  check_sub "ERROR level" s "level=ERROR";
  check_sub "message" s "requesting products failed"

let injection_test () =
  let t = create () in
  info t "unauthorized request"
    [ "path", S "/x level=ERROR msg=\"injected\"";
      "method", S "GET" ];
  let s = contents t in
  check_sub "no injected level" s "level=INFO";   (* the real one *)
  check_sub "no injected msg" s "msg=\"unauthorized request\""; (* the real msg *)
  (* the crafted value must be quoted+escaped, so the fake fields are NOT
     emitted as bare k=v tokens. The unquoted injection form must not appear. *)
  check_sub "path value quoted" s "path=\"/x level=ERROR msg=\\\"injected\\\"\"";
  Alcotest.(check bool) "no bare injected fields" false (contains s "path=/x level=ERROR");
  check_sub "method stays bare" s "method=GET"

let () =
  Alcotest.run "log"
    [ ("levels",
       [ Alcotest.test_case "info" `Quick info_test
       ; Alcotest.test_case "warn" `Quick warn_test
       ; Alcotest.test_case "error" `Quick error_test
       ; Alcotest.test_case "injection" `Quick injection_test ])
    ]