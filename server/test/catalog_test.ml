(* L2a, T1: asserts the catalog fixture loads with all 16 entries in
   positional order (idx0..idx15), matching the Hurl smoke assertions in
   smoke-tests/products-catalog.hurl. The fixture is the single source of
   truth — we resolve it at the repo root rather than copying it, so a drift
   between the fixture and the tests shows up here. *)

open Apicommand
open Product
open Server_lib

(* Walk up from the cwd (a _build/... dir) to the directory containing
   dune-project, then read infra/catalog/products.json from there. *)
let repo_root () =
  let rec up d =
    if Sys.file_exists (Filename.concat d "dune-project") then d
    else
      let parent = Filename.dirname d in
      if parent = d then Alcotest.fail "could not locate repo root (dune-project)"
      else up parent
  in
  up (Sys.getcwd ())

let contains s sub =
  let n = String.length s and m = String.length sub in
  let rec go i =
    if i + m > n then false
    else if String.sub s i m = sub then true else go (i + 1)
  in
  if m = 0 then true else go 0

let fixture_path = Filename.concat (repo_root ()) "infra/catalog/products.json"

let expected =
  [ { ref = 1; description = "vélo électrique"; stock = 10; price = 1400.0 }
  ; { ref = 2; description = "balle de tennis"; stock = 1000; price = 1.5 }
  ; { ref = 3; description = "raquette de tennis"; stock = 0; price = 80.0 }
  ; { ref = 4; description = "ballon de football"; stock = 5; price = 25.0 }
  ; { ref = 5; description = "casque de vélo"; stock = 30; price = 45.6 }
  ; { ref = 6; description = "montre connectée"; stock = 18; price = 149.99 }
  ; { ref = 7; description = "chaussures de course"; stock = 25; price = 79.0 }
  ; { ref = 8; description = "tapis de yoga"; stock = 60; price = 35.5 }
  ; { ref = 9; description = "gourde isotherme"; stock = 200; price = 12.9 }
  ; { ref = 10; description = "corde à sauter"; stock = 150; price = 8.5 }
  ; { ref = 11; description = "haltères 5kg"; stock = 20; price = 39.99 }
  ; { ref = 12; description = "ballon de rugby"; stock = 22; price = 28.0 }
  ; { ref = 13; description = "raquette de badminton"; stock = 18; price = 54.99 }
  ; { ref = 14; description = "filet de tennis"; stock = 3; price = 110.0 }
  ; { ref = 15; description = "chaussures de randonnée"; stock = 0; price = 89.5 }
  ; { ref = 16; description = "sac de sport"; stock = 40; price = 34.9 } ]

(* Alcotest has no built-in product testable; compare via a (ref, desc, stock,
   price) quad so failures print readable diffs. *)
let quad (p : Product.product) = (p.ref, p.description, p.stock, p.price)
let quad_eq (r1, d1, s1, p1 : int * string * int * float) (r2, d2, s2, p2) =
  r1 = r2 && d1 = d2 && s1 = s2 && Float.equal p1 p2
let pp_quad ppf (r, d, s, p) =
  Fmt.pf ppf "ref=%d desc=%S stock=%d prix=%.2f" r d s p
let quad_testable = Alcotest.testable pp_quad quad_eq

let loads_sixteen_in_order () =
  match Catalog.load_catalog ~path:fixture_path with
  | Error e -> Alcotest.fail ("load_catalog: " ^ e)
  | Ok got ->
    Alcotest.(check int) "16 entries" 16 (List.length got);
    Alcotest.(check (list quad_testable))
      "positional order idx0..idx15"
      (List.map quad expected)
      (List.map quad got)

let round_trips_byte_exact () =
  (* The served catalog is [Wire.encode_products] of the loaded list. Verify
     integral prices render as ints (1400, not 1400.0) — load-bearing for the
     Hurl [jsonpath "$[0].prix" == 1400] assertions. *)
  match Catalog.load_catalog ~path:fixture_path with
  | Error e -> Alcotest.fail ("load_catalog: " ^ e)
  | Ok ps ->
    let s = Wire.encode_products ps in
    Alcotest.(check bool) "idx0 prix renders as int 1400"
      true
      (try
         let i = String.index s '}' in
         (* first object ends at first '}' *)
         let first = String.sub s 0 (i + 1) in
         contains first "\"prix\":1400" && not (contains first "1400.0")
       with Not_found -> false)

let () =
  Alcotest.run "catalog"
    [ ("load",
       [ Alcotest.test_case "16 entries in positional order" `Quick loads_sixteen_in_order
       ; Alcotest.test_case "integral prix renders as JSON int" `Quick round_trips_byte_exact ]) ]