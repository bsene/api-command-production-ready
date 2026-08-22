(* Alcotest suite for the Quantity smart constructor and CartItem.Validate
   (L1a, T1). *)

open Apicommand.Product

let contains_sub s sub =
  let n = String.length s and m = String.length sub in
  let rec go i =
    if i + m > n then false
    else if String.sub s i m = sub then true else go (i + 1)
  in
  go 0

(* --- TestNewQuantity_rejectsNonPositive --- *)
let reject_non_positive () =
  List.iter (fun n ->
    match create_quantity n with
    | Ok _ -> Alcotest.fail "non-positive quantity must be rejected"
    | Error (`Invalid_quantity m) -> Alcotest.(check int) "carries bad value" n m)
    [ -5; -1; 0 ]

(* --- TestNewQuantity_acceptsPositive --- *)
let accept_positive () =
  match create_quantity 7 with
  | Ok q -> Alcotest.(check int) "Int() round-trips" 7 (quantity_to_int q)
  | Error _ -> Alcotest.fail "positive quantity must be accepted"

(* --- TestCartItem_Validate_rejectsNonPositive --- *)
let validate_rejects_non_positive () =
  List.iter (fun n ->
    let item = { ref = 1; quantity = n } in
    match validate_cart_item item with
    | Ok _ -> Alcotest.fail "non-positive cart quantity must be rejected"
    | Error `Invalid_quantity -> ())
    [ -3; 0 ]

(* --- TestCartItem_Validate_acceptsPositive --- *)
let validate_accepts_positive () =
  let item = { ref = 1; quantity = 2 } in
  match validate_cart_item item with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "positive cart quantity must be accepted"

(* --- invalid_cart_error message format (faithful to Go) --- *)
let invalid_cart_error_message_format () =
  let e = invalid_cart_error
      [ { ref = 1; requested = 5; available = 0; reason = NotAvailable } ] in
  Alcotest.(check int) "code is 422" 422 e.code;
  Alcotest.(check string) "message format"
    "cart invalid: 1 item(s) cannot be fulfilled"
    (invalid_cart_error_message e)

(* --- Wire: "prix" key + round-trip (L1a load-bearing French key) --- *)
let wire_prix_key_and_roundtrip () =
  let ps =
    [ { ref = 1; description = "vélo électrique"; stock = 10; price = 1400.0 } ]
  in
  let s = Apicommand.Wire.encode_products ps in
  Alcotest.(check bool) "contains \"prix\"" true (contains_sub s "\"prix\"");
  Alcotest.(check bool) "no english price key" false (contains_sub s "\"price\"");
  match Apicommand.Wire.decode_products s with
  | Ok [ p ] ->
      Alcotest.(check int) "ref round-trips" 1 p.ref;
      Alcotest.(check string) "utf-8 description round-trips"
        "vélo électrique" p.description;
      Alcotest.(check int) "stock round-trips" 10 p.stock;
      Alcotest.(check (float 0.001)) "price round-trips" 1400.0 p.price
  | _ -> Alcotest.fail "round-trip decode failed"

let () =
  Alcotest.run "product"
    [ ("quantity",
       [ Alcotest.test_case "rejects non-positive" `Quick reject_non_positive
       ; Alcotest.test_case "accepts positive" `Quick accept_positive ])
    ; ("cart_item.validate",
       [ Alcotest.test_case "rejects non-positive" `Quick validate_rejects_non_positive
       ; Alcotest.test_case "accepts positive" `Quick validate_accepts_positive ])
    ; ("invalid_cart_error",
       [ Alcotest.test_case "message format" `Quick invalid_cart_error_message_format ])
    ; ("wire",
       [ Alcotest.test_case "prix key + round-trip" `Quick wire_prix_key_and_roundtrip ])
    ]