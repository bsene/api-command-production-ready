(* client_smoke — standalone smoke executable that drives the real
   Orders_manager client (via Cohttp_backend) against the live products API
   fixture. Closes the A01 detection gap: the Hurl suite exercises the server
   directly and the Alcotest suite exercises the client against a mock, but
   nothing previously exercised the real OCaml client against the authenticated
   server. Plain assertions + exit 1 (smoke philosophy: fail fast, clear
   output), not Alcotest — this is a live-server gate, not a unit test. *)

open Apicommand

let run = Lwt_main.run

let failures = ref 0

let check label cond =
  if cond then Printf.printf "PASS  %s\n" label
  else begin
    Printf.printf "FAIL  %s\n" label;
    incr failures
  end

let check_int label expected got =
  if expected = got then Printf.printf "PASS  %s\n" label
  else begin
    Printf.printf "FAIL  %s (expected %d, got %d)\n" label expected got;
    incr failures
  end

let check_float label expected got =
  if Float.abs (expected -. got) < 0.001 then Printf.printf "PASS  %s\n" label
  else begin
    Printf.printf "FAIL  %s (expected %g, got %g)\n" label expected got;
    incr failures
  end

let check_int_list label expected got =
  if expected = got then Printf.printf "PASS  %s\n" label
  else begin
    let str l = String.concat "," (List.map string_of_int l) in
    Printf.printf "FAIL  %s (expected [%s], got [%s])\n" label (str expected) (str got);
    incr failures
  end

let contains ~sub s =
  let n = String.length sub in
  let m = String.length s in
  let rec go i =
    if i + n > m then false
    else if String.sub s i n = sub then true
    else go (i + 1)
  in
  n = 0 || go 0

let parse_args () =
  let base_url = ref "http://127.0.0.1:18080" in
  let api_key = ref "smoke-test-key" in
  let rec go = function
    | "--base-url" :: v :: rest -> base_url := v; go rest
    | "--api-key" :: v :: rest -> api_key := v; go rest
    | _ :: rest -> go rest
    | [] -> ()
  in
  go (List.tl (Array.to_list Sys.argv));
  (!base_url, !api_key)

let make_manager ~base_url ~api_key =
  let backend = Cohttp_backend.make ~allow_local_dev:true () in
  Orders_manager.create ~base_url ~http_client:backend ~allow_insecure_http:true
    ~api_key ()

let () =
  let base_url, api_key = parse_args () in
  (match make_manager ~base_url ~api_key with
   | Error e -> Printf.printf "FAIL  create manager: %s\n" e; exit 1
   | Ok m ->
     (* --- catalog shape (16 products, refs 3 and 15 out of stock) --------- *)
     (match run (Orders_manager.all_descriptions m) with
      | Error e -> check ("all_descriptions: " ^ e) false
      | Ok ds ->
        check_int "all_descriptions count = 16" 16 (List.length ds);
        check "all_descriptions sorted" (ds = List.sort String.compare ds);
        (match ds with
         | first :: _ -> check "all_descriptions first = balle de tennis" (first = "balle de tennis")
         | [] -> check "all_descriptions first" false);
        (match List.rev ds with
         | last :: _ -> check "all_descriptions last = vélo électrique" (last = "vélo électrique")
         | [] -> check "all_descriptions last" false));

     (match run (Orders_manager.available_descriptions m) with
      | Error e -> check ("available_descriptions: " ^ e) false
      | Ok ds -> check_int "available_descriptions count = 14" 14 (List.length ds));

     (match run (Orders_manager.is_available m 1) with
      | Ok true -> check "is_available 1 = true" true
      | Ok false -> check "is_available 1 = true" false
      | Error e -> check ("is_available 1: " ^ e) false);

     (match run (Orders_manager.is_available m 3) with
      | Ok false -> check "is_available 3 = false" true
      | Ok true -> check "is_available 3 = false" false
      | Error e -> check ("is_available 3: " ^ e) false);

     (match run (Orders_manager.is_available m 15) with
      | Ok false -> check "is_available 15 = false" true
      | Ok true -> check "is_available 15 = false" false
      | Error e -> check ("is_available 15: " ^ e) false);

     (match run (Orders_manager.search m "tennis") with
      | Error e -> check ("search tennis: " ^ e) false
      | Ok rs ->
        let refs =
          List.map (fun (r : Orders_manager.search_result) -> r.ref) rs
          |> List.sort compare
        in
        check_int_list "search tennis refs = [2;3;14]" [ 2; 3; 14 ] refs);

     (* --- cart validation ------------------------------------------------- *)
     (match run (Orders_manager.validate_cart m
                   [ { ref = 1; quantity = 2 }; { ref = 2; quantity = 3 } ]) with
      | Error (`Fetch e) -> check ("validate_cart valid: fetch " ^ e) false
      | Error (`Invalid_cart _) ->
        check "validate_cart valid (expected Ok)" false
      | Ok v ->
        check "validate_cart valid flag" v.valid;
        check_float "validate_cart valid total = 2804.5" 2804.5 v.total_price);

     (match run (Orders_manager.validate_cart m [ { ref = 3; quantity = 1 } ]) with
      | Error (`Invalid_cart e) -> check_int "validate_cart out-of-stock code = 422" 422 e.code
      | Error (`Fetch e) -> check ("validate_cart out-of-stock: fetch " ^ e) false
      | Ok _ -> check "validate_cart out-of-stock (expected 422)" false);

     (* --- A01 regression: wrong key fails, right key succeeds ------------- *)
     (match make_manager ~base_url ~api_key:"wrong-key" with
      | Error e -> check ("A01 wrong-key create: " ^ e) false
      | Ok bad ->
        (match run (Orders_manager.all_descriptions bad) with
         | Error e -> check "A01 wrong key rejected (401)" (contains ~sub:"status 401" e)
         | Ok _ -> check "A01 wrong key rejected (401)" false));

     (match run (Orders_manager.all_descriptions m) with
      | Ok _ -> check "A01 right key accepted" true
      | Error e -> check ("A01 right key accepted: " ^ e) false));

  if !failures > 0 then begin
    Printf.printf "\n%d assertion(s) failed\n" !failures;
    exit 1
  end else begin
    Printf.printf "\nall assertions passed\n";
    exit 0
  end
