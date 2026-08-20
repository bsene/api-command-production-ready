(* Alcotest port of the Go white-box tests in orders_manager_test.go (L1e, T1).
   Covers fetch request building, descriptions, availability, search, cart
   validation, constructor SSRF checks, api-key header, negative-quantity
   handling, and slog-substring log capture. SSRF IP-classification cases live
   in ssrf_test; the Lambda/TLS transport cases are deferred to G2/G3. *)

open Apicommand
open Product
open Lwt

module type HB = Orders_manager.HTTP_BACKEND

let run x = Lwt_main.run x

let contains s sub =
  let n = String.length s and m = String.length sub in
  let rec go i =
    if i + m > n then false
    else if String.sub s i m = sub then true else go (i + 1)
  in
  if m = 0 then true else go 0

(* --- fake transport: records the outgoing request, returns a canned response -- *)

type seen = {
  mutable method_ : string;
  mutable url : string;
  mutable headers : (string * string) list;
}

let fake_backend ~status ~body ?(delay = 0.0) () =
  let s = { method_ = ""; url = ""; headers = [] } in
  let module M : HB = struct
    type response = { st : int; bd : string }
    let request ~method_ ~url ~headers =
      s.method_ <- method_;
      s.url <- url;
      s.headers <- headers;
      (if delay > 0.0 then Lwt_unix.sleep delay else Lwt.return_unit)
      >>= fun () -> Lwt.return (Ok { st = status; bd = body })
    let status r = r.st
    let body r = r.bd
  end in
  (module M : HB), s

let error_backend () =
  let module M : HB = struct
    type response = unit
    let request ~method_:_ ~url:_ ~headers:_ =
      Lwt.return (Error "upstream unreachable: simulated network failure")
    let status _ = 0
    let body _ = ""
  end in
  (module M : HB)

let sample_products =
  [ { ref = 1; description = "vélo électrique"; stock = 10; price = 1400.0 }
  ; { ref = 2; description = "balle de tennis"; stock = 1000; price = 1.5 }
  ; { ref = 3; description = "raquette de tennis"; stock = 0; price = 80.0 }
  ; { ref = 4; description = "ballon de football"; stock = 5; price = 25.0 } ]

let products_json = Wire.encode_products sample_products

let manager_with_transport ~status ~body =
  let backend, s = fake_backend ~status ~body () in
  match Orders_manager.create ~base_url:"https://products.com" ~http_client:backend () with
  | Ok m -> m, s
  | Error e -> Alcotest.fail ("create: " ^ e)

let manager_only ~status ~body = fst (manager_with_transport ~status ~body)

(* --- fetch / request building ---------------------------------------------- *)

let builds_correct_request () =
  let m, s = manager_with_transport ~status:200 ~body:products_json in
  (match run (Orders_manager.all_descriptions m) with
   | Error e -> Alcotest.fail ("unexpected error: " ^ e)
   | Ok _ -> ());
  Alcotest.(check string) "method GET" "GET" s.method_;
  Alcotest.(check string) "url" "https://products.com/products" s.url

let error_status () =
  let m = manager_only ~status:500 ~body:"boom" in
  match run (Orders_manager.all_descriptions m) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error on 500"

let invalid_json () =
  let m = manager_only ~status:200 ~body:"not json" in
  match run (Orders_manager.all_descriptions m) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error on invalid JSON"

let cancelled_context () =
  let backend, _ = fake_backend ~status:200 ~body:products_json ~delay:0.050 () in
  match Orders_manager.create ~base_url:"https://products.com"
          ~http_client:backend ~timeout_ms:5.0 () with
  | Error e -> Alcotest.fail e
  | Ok m ->
    (match run (Orders_manager.all_descriptions m) with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "expected error on cancelled context")

(* --- descriptions / availability / search ---------------------------------- *)

let all_descriptions () =
  let m = manager_only ~status:200 ~body:products_json in
  match run (Orders_manager.all_descriptions m) with
  | Error e -> Alcotest.fail e
  | Ok got ->
    Alcotest.(check (list string))
      "sorted descriptions"
      [ "balle de tennis"; "ballon de football"; "raquette de tennis"; "vélo électrique" ]
      got

let available_descriptions () =
  let m = manager_only ~status:200 ~body:products_json in
  match run (Orders_manager.available_descriptions m) with
  | Error e -> Alcotest.fail e
  | Ok got ->
    Alcotest.(check (list string))
      "available only"
      [ "balle de tennis"; "ballon de football"; "vélo électrique" ] got

let is_available_in_stock () =
  let m = manager_only ~status:200 ~body:products_json in
  match run (Orders_manager.is_available m 1) with
  | Error e -> Alcotest.fail e
  | Ok b -> Alcotest.(check bool) "in stock" true b

let is_available_out_of_stock () =
  let m = manager_only ~status:200 ~body:products_json in
  match run (Orders_manager.is_available m 3) with
  | Error e -> Alcotest.fail e
  | Ok b -> Alcotest.(check bool) "out of stock" false b

let is_available_unknown_ref () =
  let m = manager_only ~status:200 ~body:products_json in
  match run (Orders_manager.is_available m 999) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for unknown ref"

let search_find ref = List.find (fun (r : Orders_manager.search_result) -> r.ref = ref)

let search_tennis () =
  let m = manager_only ~status:200 ~body:products_json in
  match run (Orders_manager.search m "tennis") with
  | Error e -> Alcotest.fail e
  | Ok rs ->
    Alcotest.(check int) "2 results" 2 (List.length rs);
    let balle = search_find 2 rs in
    Alcotest.(check bool) "balle available" true balle.available;
    Alcotest.(check (float 0.001)) "balle price" 1.5 balle.price;
    let raquette = search_find 3 rs in
    Alcotest.(check bool) "raquette unavailable" false raquette.available;
    Alcotest.(check (float 0.001)) "raquette price" 80.0 raquette.price

let search_case_insensitive () =
  let m = manager_only ~status:200 ~body:products_json in
  match run (Orders_manager.search m "TENNIS") with
  | Error e -> Alcotest.fail e
  | Ok rs -> Alcotest.(check int) "TENNIS 2 results" 2 (List.length rs)

let search_no_match () =
  let m = manager_only ~status:200 ~body:products_json in
  match run (Orders_manager.search m "surf") with
  | Error e -> Alcotest.fail e
  | Ok rs -> Alcotest.(check int) "no match" 0 (List.length rs)

(* --- cart validation ------------------------------------------------------- *)

let expect_invalid ~label cart =
  let m = manager_only ~status:200 ~body:products_json in
  match run (Orders_manager.validate_cart m cart) with
  | Ok v -> Alcotest.fail (Printf.sprintf "%s: expected error, got valid total=%g" label v.total_price)
  | Error (`Fetch e) -> Alcotest.fail (Printf.sprintf "%s: unexpected fetch error: %s" label e)
  | Error (`Invalid_cart e) -> e

let expect_valid ~label ~total cart =
  let m = manager_only ~status:200 ~body:products_json in
  match run (Orders_manager.validate_cart m cart) with
  | Error (`Fetch e) -> Alcotest.fail (label ^ ": fetch: " ^ e)
  | Error (`Invalid_cart e) ->
    Alcotest.fail (Printf.sprintf "%s: expected valid, got invalid (%d detail(s))" label
                     (List.length e.details))
  | Ok v ->
    Alcotest.(check bool) (label ^ ": valid") true v.valid;
    Alcotest.(check (float 0.001)) (label ^ ": total") total v.total_price

let validate_cart_valid () =
  expect_valid ~label:"valid cart"
    ~total:(1400.0 *. 2.0 +. 1.5 *. 3.0)
    [ { ref = 1; quantity = 2 }; { ref = 2; quantity = 3 } ]

let validate_cart_empty () =
  expect_valid ~label:"empty cart" ~total:0.0 []

let validate_cart_out_of_stock () =
  let e = expect_invalid ~label:"out of stock" [ { ref = 3; quantity = 1 } ] in
  Alcotest.(check int) "code 422" 422 e.code;
  Alcotest.(check bool) "has details" true (List.length e.details > 0)

let validate_cart_qty_exceeds_stock () =
  let e = expect_invalid ~label:"qty exceeds stock" [ { ref = 1; quantity = 100 } ] in
  Alcotest.(check int) "code 422" 422 e.code

let validate_cart_unknown () =
  let e = expect_invalid ~label:"unknown product" [ { ref = 999; quantity = 1 } ] in
  Alcotest.(check int) "code 422" 422 e.code

let validate_cart_mixed () =
  let e = expect_invalid ~label:"mixed valid/invalid"
            [ { ref = 1; quantity = 1 }; { ref = 3; quantity = 1 } ] in
  Alcotest.(check int) "code 422" 422 e.code

let rejects_negative_quantity () =
  let e = expect_invalid ~label:"negative qty" [ { ref = 1; quantity = -2 } ] in
  Alcotest.(check int) "1 detail" 1 (List.length e.details);
  let d = List.hd e.details in
  Alcotest.(check bool) "reason InvalidQuantity" true (d.reason = InvalidQuantity);
  Alcotest.(check int) "requested -2" (-2) d.requested

let rejects_zero_quantity () =
  let e = expect_invalid ~label:"zero qty" [ { ref = 1; quantity = 0 } ] in
  let d = List.hd e.details in
  Alcotest.(check bool) "reason InvalidQuantity" true (d.reason = InvalidQuantity)

let negative_does_not_reduce_total () =
  let _ = expect_invalid ~label:"negative cannot reduce total"
            [ { ref = 1; quantity = 2 }; { ref = 2; quantity = -5 } ] in
  ()

let negative_and_valid_mixed () =
  let e = expect_invalid ~label:"negative+valid mixed"
            [ { ref = 1; quantity = 1 }; { ref = 2; quantity = -3 }; { ref = 3; quantity = 1 } ]
  in
  Alcotest.(check int) "2 issues" 2 (List.length e.details)

(* --- constructor SSRF / scheme checks (A04 / A10) ------------------------- *)

let rejects url =
  match Orders_manager.create ~base_url:url () with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail (Printf.sprintf "expected error for %s" url)

let accepts url =
  match Orders_manager.create ~base_url:url () with
  | Ok _ -> ()
  | Error e -> Alcotest.fail (Printf.sprintf "unexpected error for %s: %s" url e)

let new_rejects_http_by_default () = rejects "http://products.com"
let new_rejects_empty () = rejects ""
let new_accepts_https () = accepts "https://products.com"
let new_rejects_metadata_ip () = rejects "https://169.254.169.254"

let new_rejects_metadata_over_http_insecure () =
  match Orders_manager.create ~base_url:"http://169.254.169.254"
          ~allow_insecure_http:true () with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected link-local blocked even with insecure opt-in"

let new_rejects_private_ip () =
  List.iter rejects [ "https://10.0.0.1"; "https://172.16.0.1"; "https://192.168.1.1" ]

let new_rejects_loopback_https () = rejects "https://127.0.0.1"
let new_rejects_unspecified_ip () = rejects "https://0.0.0.0"
let new_rejects_invalid_scheme () = rejects "ftp://products.com"

let new_allows_http_insecure_opt_in () =
  match Orders_manager.create ~base_url:"http://127.0.0.1:18080"
          ~allow_insecure_http:true () with
  | Error e -> Alcotest.fail e
  | Ok m ->
    let b = Orders_manager.base_url m in
    Alcotest.(check bool) "baseURL has http:// prefix"
      true (String.length b >= 7 && String.sub b 0 7 = "http://")

let new_allows_loopback_insecure_http () =
  match Orders_manager.create ~base_url:"http://127.0.0.1:18080"
          ~allow_insecure_http:true () with
  | Error e -> Alcotest.fail e
  | Ok _ -> ()

(* --- api-key header (A01) --------------------------------------------------- *)

let sends_api_key_header () =
  let backend, s = fake_backend ~status:200 ~body:products_json () in
  (match Orders_manager.create ~base_url:"https://products.com"
          ~http_client:backend ~api_key:"secret-key" () with
   | Error e -> Alcotest.fail e
   | Ok m ->
     (match run (Orders_manager.all_descriptions m) with
      | Error e -> Alcotest.fail e
      | Ok _ -> ()));
  let got = try List.assoc "x-api-key" s.headers with Not_found -> "" in
  Alcotest.(check string) "x-api-key sent" "secret-key" got

let omits_api_key_when_not_set () =
  let backend, s = fake_backend ~status:200 ~body:products_json () in
  (match Orders_manager.create ~base_url:"https://products.com"
          ~http_client:backend () with
   | Error e -> Alcotest.fail e
   | Ok m ->
     (match run (Orders_manager.all_descriptions m) with
      | Error e -> Alcotest.fail e
      | Ok _ -> ()));
  Alcotest.(check bool) "no x-api-key header"
    false (List.mem_assoc "x-api-key" s.headers)

(* --- structured logging (A09) ---------------------------------------------- *)

let logs_upstream_error () =
  let backend, _ = fake_backend ~status:500 ~body:"boom" () in
  let logger = Log.create () in
  (match Orders_manager.create ~base_url:"https://products.com"
          ~http_client:backend ~logger () with
   | Error e -> Alcotest.fail e
   | Ok m -> ignore (run (Orders_manager.all_descriptions m) : (string list, string) result));
  let logged = Log.contents logger in
  Alcotest.(check bool) "WARN level" true (contains logged "level=WARN");
  Alcotest.(check bool) "non-OK status msg"
    true (contains logged "products API returned non-OK status");
  Alcotest.(check bool) "status=500" true (contains logged "status=500")

let logs_transport_error () =
  let backend = error_backend () in
  let logger = Log.create () in
  (match Orders_manager.create ~base_url:"https://products.com"
          ~http_client:backend ~logger () with
   | Error e -> Alcotest.fail e
   | Ok m -> ignore (run (Orders_manager.all_descriptions m) : (string list, string) result));
  let logged = Log.contents logger in
  Alcotest.(check bool) "ERROR level" true (contains logged "level=ERROR");
  Alcotest.(check bool) "transport-error msg"
    true (contains logged "requesting products failed")

let logs_successful_request () =
  let backend, _ = fake_backend ~status:200 ~body:products_json () in
  let logger = Log.create () in
  (match Orders_manager.create ~base_url:"https://products.com"
          ~http_client:backend ~logger () with
   | Error e -> Alcotest.fail e
   | Ok m -> ignore (run (Orders_manager.all_descriptions m) : (string list, string) result));
  let logged = Log.contents logger in
  Alcotest.(check bool) "INFO level" true (contains logged "level=INFO");
  Alcotest.(check bool) "completion msg"
    true (contains logged "products request completed");
  Alcotest.(check bool) "status=200" true (contains logged "status=200")

let logs_validation_failure () =
  let m, _ = manager_with_transport ~status:200 ~body:products_json in
  let logger = Log.create () in
  Orders_manager.set_logger m logger;
  (match run (Orders_manager.validate_cart m
                [ { ref = 1; quantity = -2 }; { ref = 999; quantity = 1 } ]) with
   | Error (`Invalid_cart _) -> ()
   | _ -> Alcotest.fail "expected cart validation error");
  let logged = Log.contents logger in
  Alcotest.(check bool) "WARN level" true (contains logged "level=WARN");
  Alcotest.(check bool) "validation-failed msg"
    true (contains logged "cart validation failed");
  Alcotest.(check bool) "invalid_count=2" true (contains logged "invalid_count=2")

let () =
  Alcotest.run "orders_manager"
    [ ("fetch",
       [ Alcotest.test_case "builds correct request" `Quick builds_correct_request
       ; Alcotest.test_case "error status" `Quick error_status
       ; Alcotest.test_case "invalid JSON" `Quick invalid_json
       ; Alcotest.test_case "cancelled context" `Quick cancelled_context ])
    ; ("descriptions",
       [ Alcotest.test_case "all descriptions" `Quick all_descriptions
       ; Alcotest.test_case "available descriptions" `Quick available_descriptions ])
    ; ("availability",
       [ Alcotest.test_case "in stock" `Quick is_available_in_stock
       ; Alcotest.test_case "out of stock" `Quick is_available_out_of_stock
       ; Alcotest.test_case "unknown ref errors" `Quick is_available_unknown_ref ])
    ; ("search",
       [ Alcotest.test_case "tennis" `Quick search_tennis
       ; Alcotest.test_case "case insensitive" `Quick search_case_insensitive
       ; Alcotest.test_case "no match" `Quick search_no_match ])
    ; ("validate_cart",
       [ Alcotest.test_case "valid cart" `Quick validate_cart_valid
       ; Alcotest.test_case "empty cart" `Quick validate_cart_empty
       ; Alcotest.test_case "out of stock" `Quick validate_cart_out_of_stock
       ; Alcotest.test_case "qty exceeds stock" `Quick validate_cart_qty_exceeds_stock
       ; Alcotest.test_case "unknown product" `Quick validate_cart_unknown
       ; Alcotest.test_case "mixed" `Quick validate_cart_mixed
       ; Alcotest.test_case "rejects negative" `Quick rejects_negative_quantity
       ; Alcotest.test_case "rejects zero" `Quick rejects_zero_quantity
       ; Alcotest.test_case "negative does not reduce total" `Quick negative_does_not_reduce_total
       ; Alcotest.test_case "negative + valid mixed" `Quick negative_and_valid_mixed ])
    ; ("new_orders_manager",
       [ Alcotest.test_case "rejects http by default" `Quick new_rejects_http_by_default
       ; Alcotest.test_case "rejects empty" `Quick new_rejects_empty
       ; Alcotest.test_case "accepts https" `Quick new_accepts_https
       ; Alcotest.test_case "rejects metadata IP" `Quick new_rejects_metadata_ip
       ; Alcotest.test_case "rejects metadata over http+insecure" `Quick new_rejects_metadata_over_http_insecure
       ; Alcotest.test_case "rejects private IP" `Quick new_rejects_private_ip
       ; Alcotest.test_case "rejects loopback https" `Quick new_rejects_loopback_https
       ; Alcotest.test_case "rejects unspecified IP" `Quick new_rejects_unspecified_ip
       ; Alcotest.test_case "rejects invalid scheme" `Quick new_rejects_invalid_scheme
       ; Alcotest.test_case "allows http insecure opt-in" `Quick new_allows_http_insecure_opt_in
       ; Alcotest.test_case "allows loopback insecure http" `Quick new_allows_loopback_insecure_http ])
    ; ("api_key",
       [ Alcotest.test_case "sends api key header" `Quick sends_api_key_header
       ; Alcotest.test_case "omits api key when not set" `Quick omits_api_key_when_not_set ])
    ; ("logging",
       [ Alcotest.test_case "upstream error" `Quick logs_upstream_error
       ; Alcotest.test_case "transport error" `Quick logs_transport_error
       ; Alcotest.test_case "successful request" `Quick logs_successful_request
       ; Alcotest.test_case "validation failure" `Quick logs_validation_failure ])
    ]