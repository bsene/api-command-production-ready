(* L3a/L3b, T1: ports the white-box Lambda handler tests in
   infra/lambda/main_test.go plus a dedicated byte-equality case for the
   availability message (risk #4: OCaml [%S] would diverge from Go [%q] on
   Unicode). The handler is pure, so each test injects [api_key] and [catalog]
   directly — no package-level mutable state to swap. *)

open Lambda_lib

let key = "0123456789abcdef0123456789abcdef"
let logger = Apicommand.Log.create ()

let event ?(method_ = "POST") ?(raw_path = "") ?(is_base64 = false) ~body
    ?(headers = []) () : Event.event =
  { Event.headers; body; is_base64_encoded = is_base64; raw_path; method_ }

let handle ?(api_key = key) ?(catalog = []) ev : Event.response =
  Lambda_handler.handle ~logger ~api_key ~catalog ev

let status (r : Event.response) = r.Event.status_code

let body (r : Event.response) = r.Event.body

let message_of b =
  match Yojson.Safe.from_string b with
  | `Assoc a -> (match List.assoc_opt "message" a with Some (`String s) -> s | _ -> "")
  | _ -> ""

let ok_of b =
  match Yojson.Safe.from_string b with
  | `Assoc a -> (match List.assoc_opt "ok" a with Some (`Bool v) -> v | _ -> false)
  | _ -> false

let ref_of b =
  match Yojson.Safe.from_string b with
  | `Assoc a -> (match List.assoc_opt "ref" a with Some (`Int v) -> v | _ -> 0)
  | _ -> 0

let error_of b =
  match Yojson.Safe.from_string b with
  | `Assoc a -> (match List.assoc_opt "error" a with Some (`String s) -> s | _ -> "")
  | _ -> ""

(* --- A01: auth gate (TestHandle AuthGate cases) --------------------------- *)

let rejects_missing_key () =
  let r = handle (event ~body:{|{"ref":1,"stock":5}|} ~headers:[] ()) in
  Alcotest.(check int) "missing key -> 401" 401 (status r)

let rejects_wrong_key () =
  let r = handle (event ~body:{|{"ref":1,"stock":5}|}
                    ~headers:[ "x-api-key", "wrong-key" ] ()) in
  Alcotest.(check int) "wrong key -> 401" 401 (status r)

let rejects_empty_configured_key () =
  let r = handle ~api_key:""
      (event ~body:{|{"ref":1,"stock":5}|}
         ~headers:[ "x-api-key", key ] ()) in
  Alcotest.(check int) "no configured key -> 500" 500 (status r)

let admits_matching_key () =
  let r = handle (event ~body:{|{"ref":1,"stock":5}|}
                    ~headers:[ "x-api-key", key ] ()) in
  Alcotest.(check int) "matching key -> 200" 200 (status r)

(* --- body handling (L3 base64, L2 validation) ----------------------------- *)

let base64_body_decoded () =
  let raw = {|{"ref":1,"description":"vélo","stock":5,"price":100}|} in
  let b64 = Base64.encode_exn raw in
  let r = handle (event ~body:b64 ~is_base64:true
                    ~headers:[ "x-api-key", key ] ()) in
  Alcotest.(check int) "base64 body -> 200" 200 (status r);
  Alcotest.(check bool) "ok=true" true (ok_of (body r))

let invalid_base64_rejected () =
  let r = handle (event ~body:"not-base64!!" ~is_base64:true
                    ~headers:[ "x-api-key", key ] ()) in
  Alcotest.(check int) "invalid base64 -> 400" 400 (status r)

let rejects_negative_price () =
  let r = handle (event ~body:{|{"ref":1,"stock":5,"price":-1}|}
                    ~headers:[ "x-api-key", key ] ()) in
  Alcotest.(check int) "negative price -> 400" 400 (status r)

let rejects_negative_ref () =
  let r = handle (event ~body:{|{"ref":-1,"stock":5}|}
                    ~headers:[ "x-api-key", key ] ()) in
  Alcotest.(check int) "negative ref -> 400" 400 (status r)

let rejects_oversize_description () =
  let big = String.make 1025 'x' in
  let r = handle (event ~body:(Printf.sprintf
                    {|{"ref":1,"description":"%s","stock":5}|} big)
                    ~headers:[ "x-api-key", key ] ()) in
  Alcotest.(check int) "oversize description -> 400" 400 (status r)

let allows_zero_price_and_ref () =
  let r = handle (event ~body:{|{"ref":0,"stock":5,"price":0}|}
                    ~headers:[ "x-api-key", key ] ()) in
  Alcotest.(check int) "zero price/ref -> 200" 200 (status r)

let missing_body_rejected () =
  let r = handle (event ~body:"   " ~headers:[ "x-api-key", key ] ()) in
  Alcotest.(check int) "missing body -> 400" 400 (status r);
  Alcotest.(check string) "missing body msg" "missing request body"
    (error_of (body r))

let invalid_json_rejected () =
  let r = handle (event ~body:"{not json" ~headers:[ "x-api-key", key ] ()) in
  Alcotest.(check int) "invalid json -> 400" 400 (status r);
  Alcotest.(check string) "invalid body msg" "invalid request body"
    (error_of (body r))

(* --- GET /products catalog route ----------------------------------------- *)

let velo = { Apicommand.Product.ref = 1; description = "vélo"; stock = 10; price = 1400.0 }

let get_products_serves_catalog () =
  let r = handle ~catalog:[ velo ]
      (event ~method_:"GET" ~raw_path:"/products" ~body:""
         ~headers:[ "x-api-key", key ] ()) in
  Alcotest.(check int) "GET /products -> 200" 200 (status r);
  match Yojson.Safe.from_string (body r) with
  | `List xs -> Alcotest.(check int) "1 catalog entry" 1 (List.length xs)
  | _ -> Alcotest.fail "catalog body is not a JSON array"

let get_products_empty_when_layer_missing () =
  let r = handle
      (event ~method_:"GET" ~raw_path:"/products" ~body:""
         ~headers:[ "x-api-key", key ] ()) in
  Alcotest.(check int) "GET /products empty -> 200" 200 (status r);
  Alcotest.(check string) "empty array body" "[]" (String.trim (body r))

(* --- real fixture: GET /products serves all 16 in positional order -------- *)

let repo_root () =
  let rec up d =
    if Sys.file_exists (Filename.concat d "dune-project") then d
    else
      let parent = Filename.dirname d in
      if parent = d then Alcotest.fail "could not locate repo root"
      else up parent
  in
  up (Sys.getcwd ())

let fixture = Filename.concat (repo_root ()) "infra/catalog/products.json"

let load_catalog () =
  let read_file p =
    let ic = open_in_bin p in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in_noerr ic; s
  in
  match Apicommand.Wire.decode_products (read_file fixture) with
  | Ok ps -> ps
  | Error e -> Alcotest.fail ("catalog load failed: " ^ e)

let get_products_serves_full_fixture () =
  let catalog = load_catalog () in
  let r = handle ~catalog
      (event ~method_:"GET" ~raw_path:"/products" ~body:""
         ~headers:[ "x-api-key", key ] ()) in
  Alcotest.(check int) "full fixture -> 200" 200 (status r);
  (match Yojson.Safe.from_string (body r) with
   | `List xs ->
     Alcotest.(check int) "16 entries" 16 (List.length xs);
     (match xs with
      | h :: _ ->
        (match h with
         | `Assoc a ->
           (match List.assoc_opt "ref" a with
            | Some (`Int 1) -> ()
            | _ -> Alcotest.fail "idx0 ref=1")
         | _ -> Alcotest.fail "idx0 not an object")
      | _ -> Alcotest.fail "empty catalog")
   | _ -> Alcotest.fail "not a JSON array")

(* --- risk #4: availability message byte-equality vs Go %q/%.2f/%v --------- *)

let availability_message () =
  (* in-stock: é preserved, integral price renders with .00, available=true *)
  let r = handle (event ~body:{|{"ref":1,"description":"vélo électrique","stock":10,"price":1400}|}
                    ~headers:[ "x-api-key", key ] ()) in
  Alcotest.(check string) "in-stock message"
    "ref=1 description=\"vélo électrique\" stock=10 price=1400.00 -> available=true"
    (message_of (body r));
  (* fractional prices keep two decimals *)
  let r2 = handle (event ~body:{|{"ref":2,"description":"balle","stock":3,"price":1.5}|}
                     ~headers:[ "x-api-key", key ] ()) in
  Alcotest.(check string) "price 1.5"
    "ref=2 description=\"balle\" stock=3 price=1.50 -> available=true"
    (message_of (body r2));
  let r3 = handle (event ~body:{|{"ref":3,"description":"sac","stock":0,"price":34.9}|}
                     ~headers:[ "x-api-key", key ] ()) in
  Alcotest.(check string) "out-of-stock message"
    "ref=3 description=\"sac\" stock=0 price=34.90 -> available=false"
    (message_of (body r3));
  Alcotest.(check bool) "ok=false" false (ok_of (body r3));
  Alcotest.(check int) "ref echoed" 3 (ref_of (body r3))

let () =
  Alcotest.run "lambda"
    [ ("auth",
       [ Alcotest.test_case "rejects missing key" `Quick rejects_missing_key
       ; Alcotest.test_case "rejects wrong key" `Quick rejects_wrong_key
       ; Alcotest.test_case "rejects empty configured key" `Quick rejects_empty_configured_key
       ; Alcotest.test_case "admits matching key" `Quick admits_matching_key ])
    ; ("body",
       [ Alcotest.test_case "base64 body decoded" `Quick base64_body_decoded
       ; Alcotest.test_case "invalid base64 rejected" `Quick invalid_base64_rejected
       ; Alcotest.test_case "rejects negative price" `Quick rejects_negative_price
       ; Alcotest.test_case "rejects negative ref" `Quick rejects_negative_ref
       ; Alcotest.test_case "rejects oversize description" `Quick rejects_oversize_description
       ; Alcotest.test_case "allows zero price and ref" `Quick allows_zero_price_and_ref
       ; Alcotest.test_case "missing body rejected" `Quick missing_body_rejected
       ; Alcotest.test_case "invalid json rejected" `Quick invalid_json_rejected ])
    ; ("catalog",
       [ Alcotest.test_case "GET /products serves catalog" `Quick get_products_serves_catalog
       ; Alcotest.test_case "GET /products empty when layer missing" `Quick get_products_empty_when_layer_missing
       ; Alcotest.test_case "GET /products serves full fixture" `Quick get_products_serves_full_fixture ])
    ; ("message",
       [ Alcotest.test_case "availability message byte-equality" `Quick availability_message ]) ]