(* L2b, T1: ports the flag/env fallback and the startup-refusal logic of
   cmd/products-api/main.go. [Cli.resolve] is the pure flag-then-env resolver;
   [Cli.validate] mirrors Go's check order (catalog → api-key → listen addr).
   Env behaviour is driven by injected lookup functions (no process-env
   mutation): OCaml cannot [unset] an env var — [Unix.putenv x ""] sets empty,
   it does not remove the binding — so we pass [~env] closures directly. *)

open Server_lib

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

(* --- error testable ------------------------------------------------------- *)

let err_eq a b =
  match a, b with
  | Cli.No_api_key, Cli.No_api_key -> true
  | Cli.Bad_addr x, Cli.Bad_addr y -> String.equal x y
  | Cli.Bad_catalog x, Cli.Bad_catalog y -> String.equal x y
  | _ -> false

(* [Cli.validate] returns (unit, error) result; compare the whole result. *)
let res_eq a b =
  match a, b with
  | Ok (), Ok () -> true
  | Error x, Error y -> err_eq x y
  | _ -> false

let pp_res ppf = function
  | Ok () -> Fmt.pf ppf "Ok"
  | Error e -> Fmt.pf ppf "Error %a" Cli.pp_error e

let res_testable = Alcotest.testable pp_res res_eq

let cfg ?(addr = "127.0.0.1:18080") ?(catalog = fixture) ?(api_key = "k")
    ?(allow_external = false) ?(tls_cert = "") ?(tls_key = "") () =
  Cli.{ addr; catalog; api_key; allow_external; tls_cert; tls_key }

(* --- env_or --------------------------------------------------------------- *)

let env_or_returns_env () =
  let env _ = Some "hello" in
  Alcotest.(check string) "env value" "hello"
    (Cli.env_or ~env "API_CMD_TEST" "def")

let env_or_returns_fallback () =
  let env _ = None in
  Alcotest.(check string) "fallback" "def"
    (Cli.env_or ~env "API_CMD_TEST" "def")

(* --- resolve: flag-then-env fallback -------------------------------------- *)

let resolve_api_key_from_env () =
  let env name = if String.equal name "PRODUCTS_API_KEY" then Some "envkey" else None in
  let c =
    Cli.resolve ~env ~addr:"127.0.0.1:18080" ~catalog:"" ~api_key:""
      ~allow_external:false ~tls_cert:"" ~tls_key:"" ()
  in
  Alcotest.(check string) "api_key from env" "envkey" c.api_key

let resolve_catalog_from_env () =
  let env name = if String.equal name "PRODUCTS_CATALOG" then Some "/from-env.json" else None in
  let c =
    Cli.resolve ~env ~addr:"127.0.0.1:18080" ~catalog:"" ~api_key:"k"
      ~allow_external:false ~tls_cert:"" ~tls_key:"" ()
  in
  Alcotest.(check string) "catalog from env" "/from-env.json" c.catalog

let resolve_catalog_default_when_unset () =
  let env _ = None in
  let c =
    Cli.resolve ~env ~addr:"127.0.0.1:18080" ~catalog:"" ~api_key:"k"
      ~allow_external:false ~tls_cert:"" ~tls_key:"" ()
  in
  Alcotest.(check string) "catalog default" "infra/catalog/products.json"
    c.catalog

let resolve_flag_overrides_env () =
  let env name = if String.equal name "PRODUCTS_API_KEY" then Some "envkey" else None in
  let c =
    Cli.resolve ~env ~addr:"127.0.0.1:18080" ~catalog:fixture ~api_key:"flagkey"
      ~allow_external:false ~tls_cert:"" ~tls_key:"" ()
  in
  Alcotest.(check string) "flag wins over env" "flagkey" c.api_key

(* --- validate: startup refusal (Go order) --------------------------------- *)

let validate_requires_api_key () =
  let c = cfg ~api_key:"" () in
  Alcotest.(check res_testable) "no api key refused" (Error Cli.No_api_key)
    (Cli.validate c)

let validate_rejects_non_loopback () =
  let c = cfg ~addr:"0.0.0.0:18080" () in
  (match Cli.validate c with
   | Error (Cli.Bad_addr _) -> ()
   | other ->
     Alcotest.fail
       (Printf.sprintf "expected Bad_addr, got %s"
          (Fmt.str "%a" Cli.pp_error (match other with Error e -> e | Ok () -> Cli.No_api_key))))

let validate_accepts_loopback () =
  let c = cfg () in
  Alcotest.(check res_testable) "loopback ok" (Ok ()) (Cli.validate c)

let validate_accepts_non_loopback_with_opt_in () =
  let c = cfg ~addr:"0.0.0.0:18080" ~allow_external:true () in
  Alcotest.(check res_testable) "allow-external ok" (Ok ()) (Cli.validate c)

let validate_rejects_missing_catalog () =
  let c = cfg ~catalog:"nope/missing.json" () in
  (match Cli.validate c with
   | Error (Cli.Bad_catalog _) -> ()
   | _ -> Alcotest.fail "expected Bad_catalog for missing file")

(* --- parse: end-to-end cmdliner + validate -------------------------------- *)

(* A controlled env: [PRODUCTS_API_KEY] set iff [api_key] is [Some _]; everything
   else absent. Mirrors Go's [os.LookupEnv] (set-empty yields the empty string). *)
let env_with ?api_key ?catalog () =
  fun name ->
    match name with
    | "PRODUCTS_API_KEY" -> api_key
    | "PRODUCTS_CATALOG" -> catalog
    | _ -> None

let parse_missing_key_refused () =
  let env = env_with () in
  (match Cli.parse ~argv:[| "products-api"; "--catalog"; fixture |] ~env () with
   | Error Cli.No_api_key -> ()
   | other ->
     Alcotest.fail
       (Printf.sprintf "expected No_api_key, got %s"
          (Fmt.str "%a" Cli.pp_error
             (match other with Error e -> e | Ok _ -> Cli.No_api_key))))

let parse_ok_with_api_key () =
  let env = env_with () in
  (match Cli.parse
           ~argv:[| "products-api"; "--catalog"; fixture; "--api-key"; "k" |]
           ~env () with
   | Ok c -> Alcotest.(check string) "parsed api_key" "k" c.api_key
   | Error e -> Alcotest.fail (Fmt.str "parse failed: %a" Cli.pp_error e))

let parse_api_key_from_env () =
  let env = env_with ~api_key:"envkey" () in
  (match Cli.parse ~argv:[| "products-api"; "--catalog"; fixture |] ~env () with
   | Ok c -> Alcotest.(check string) "env api_key" "envkey" c.api_key
   | Error e -> Alcotest.fail (Fmt.str "parse failed: %a" Cli.pp_error e))

let () =
  Alcotest.run "cli"
    [ ("env_or",
       [ Alcotest.test_case "returns env value" `Quick env_or_returns_env
       ; Alcotest.test_case "returns fallback when unset" `Quick env_or_returns_fallback ])
    ; ("resolve",
       [ Alcotest.test_case "api-key falls back to env" `Quick resolve_api_key_from_env
       ; Alcotest.test_case "catalog falls back to env" `Quick resolve_catalog_from_env
       ; Alcotest.test_case "catalog default when env unset" `Quick resolve_catalog_default_when_unset
       ; Alcotest.test_case "flag overrides env" `Quick resolve_flag_overrides_env ])
    ; ("validate",
       [ Alcotest.test_case "requires api key" `Quick validate_requires_api_key
       ; Alcotest.test_case "rejects non-loopback" `Quick validate_rejects_non_loopback
       ; Alcotest.test_case "accepts loopback" `Quick validate_accepts_loopback
       ; Alcotest.test_case "accepts non-loopback with opt-in" `Quick validate_accepts_non_loopback_with_opt_in
       ; Alcotest.test_case "rejects missing catalog" `Quick validate_rejects_missing_catalog ])
    ; ("parse",
       [ Alcotest.test_case "missing key refused" `Quick parse_missing_key_refused
       ; Alcotest.test_case "ok with api-key flag" `Quick parse_ok_with_api_key
       ; Alcotest.test_case "api-key from env" `Quick parse_api_key_from_env ]) ]