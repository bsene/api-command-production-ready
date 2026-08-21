(* L2c, T1: ports the white-box server tests in cmd/products-api/server_test.go
   and the api-key-auth cases in main_test.go. The real Dream handler is
   exercised in-process via [Dream.test] (no port binding, which the sandbox
   disallows), mirroring Go's [httptest.NewRecorder]. *)

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

let load_catalog () =
  match Catalog.load_catalog ~path:fixture with
  | Ok c -> c
  | Error e -> Alcotest.fail (Printf.sprintf "catalog load failed: %s" e)

let logger = Apicommand.Log.create ()

(* [serve h target api_key] runs [h] in-process on a GET [target] with the given
   x-api-key (omitted when [""]), like Go's [serve]. *)
let serve h target api_key =
  let run = Dream.test h in
  let headers = if api_key = "" then [] else [ "x-api-key", api_key ] in
  let req = Dream.request ~method_:`GET ~target ~headers "" in
  run req

let status resp = Dream.status_to_int (Dream.status resp)

let body_string resp = Lwt_main.run (Dream.body resp)

(* newTestHandler: securityHeaders → apiKeyAuth → router (no logger/recovery). *)
let test_handler ~api_key catalog =
  Server.security_headers
  @@ Server.api_key_auth api_key
  @@ Dream.router [ Dream.get "/products" (Server.products_handler catalog) ]

let has_header resp name =
  match Dream.header resp name with Some v -> not (String.equal v "") | None -> false

(* --- catalog requires auth (TestIntegration_catalogRequiresAuth) ------------ *)

let catalog_requires_auth () =
  let catalog = load_catalog () in
  let h = test_handler ~api_key:"secret" catalog in
  Alcotest.(check int) "no key -> 401" 401 (status (serve h "/products" ""));
  Alcotest.(check int) "wrong key -> 401" 401 (status (serve h "/products" "nope"));
  let ok = serve h "/products" "secret" in
  Alcotest.(check int) "correct key -> 200" 200 (status ok);
  List.iter (fun name ->
    Alcotest.(check bool) ("header " ^ name) true (has_header ok name))
    [ "X-Content-Type-Options"; "X-Frame-Options"; "Cache-Control";
      "Content-Security-Policy" ];
  Alcotest.(check bool) "non-empty body" true
    (String.length (body_string ok) > 0)

(* --- unknown path (TestIntegration_unknownPathReturns404WhenAuthed) --------- *)

let unknown_path_404_when_authed () =
  let catalog = load_catalog () in
  let h = test_handler ~api_key:"secret" catalog in
  Alcotest.(check int) "authed unknown -> 404" 404
    (status (serve h "/does-not-exist" "secret"));
  Alcotest.(check int) "unauthed unknown -> 401" 401
    (status (serve h "/does-not-exist" ""))

(* --- recovery (TestRecoveryMiddleware) ----------------------------------- *)

let recovery_recovers_panic () =
  let panic _request = failwith "boom" in
  let h = Server.recover logger @@ panic in
  Alcotest.(check int) "panic -> 500" 500 (status (serve h "/products" ""))

let recovery_passes_through () =
  let ok _request = Dream.respond "" in
  let h = Server.recover logger @@ ok in
  Alcotest.(check int) "no panic -> 200" 200 (status (serve h "/products" ""))

(* --- request logger (TestRequestLogger) ---------------------------------- *)

let request_logger_captures_status () =
  let teapot _request = Dream.respond ~status:(Dream.int_to_status 418) "" in
  let h = Server.request_logger logger @@ teapot in
  Alcotest.(check int) "status 418 passes through" 418
    (status (serve h "/products" ""))

let request_logger_works_with_auth () =
  let catalog = load_catalog () in
  let h =
    Server.request_logger logger
    @@ Server.recover logger
    @@ test_handler ~api_key:"secret" catalog
  in
  Alcotest.(check int) "unauthed -> 401" 401 (status (serve h "/products" ""));
  Alcotest.(check int) "authed -> 200" 200 (status (serve h "/products" "secret"))

(* --- api key auth (TestApiKeyAuth_rejectsMissingOrWrongKey) ---------------- *)

let api_key_auth_missing () =
  let ok _request = Dream.respond "" in
  let h = Server.api_key_auth "secret" @@ ok in
  Alcotest.(check int) "missing -> 401" 401 (status (serve h "/products" ""))

let api_key_auth_wrong () =
  let ok _request = Dream.respond "" in
  let h = Server.api_key_auth "secret" @@ ok in
  Alcotest.(check int) "wrong -> 401" 401 (status (serve h "/products" "nope"))

let api_key_auth_correct () =
  let ok _request = Dream.respond "" in
  let h = Server.api_key_auth "secret" @@ ok in
  Alcotest.(check int) "correct -> 200" 200 (status (serve h "/products" "secret"))

(* --- max header bytes (TestServerConfig_hasMaxHeaderBytes) ----------------- *)

let oversized_headers () =
  let big = String.make ((1 lsl 20) + 100) 'x' in
  [ "x-api-key", "secret"; "x-large", big ]

let run_with_headers h target headers =
  let run = Dream.test h in
  let req = Dream.request ~method_:`GET ~target ~headers "" in
  run req

(* Wired through [Server.app] so the production chain is covered too. *)
let max_header_bytes_wired_in_app () =
  let catalog = load_catalog () in
  let h = Server.app ~catalog ~api_key:"secret" ~logger in
  Alcotest.(check int) "full app oversized headers -> 431" 431
    (status (run_with_headers h "/products" (oversized_headers ())))

let max_header_bytes_configured () =
  Alcotest.(check int) "MaxHeaderBytes = 1<<20" (1 lsl 20) Server.max_header_bytes

let max_header_bytes_rejects_oversized () =
  let ok _request = Dream.respond "" in
  let h = Server.enforce_max_header_bytes @@ ok in
  Alcotest.(check int) "oversized headers -> 431" 431
    (status (run_with_headers h "/products" (oversized_headers ())))

let max_header_bytes_allows_normal () =
  let ok _request = Dream.respond "" in
  let h = Server.enforce_max_header_bytes @@ ok in
  Alcotest.(check int) "normal headers -> 200" 200
    (status (run_with_headers h "/products" [ "x-api-key", "secret" ]))

let () =
  Alcotest.run "server"
    [ ("integration",
       [ Alcotest.test_case "catalog requires auth" `Quick catalog_requires_auth
       ; Alcotest.test_case "unknown path 404 when authed" `Quick unknown_path_404_when_authed
       ; Alcotest.test_case "max header bytes wired in app" `Quick max_header_bytes_wired_in_app ])
    ; ("recovery",
       [ Alcotest.test_case "recovers panic" `Quick recovery_recovers_panic
       ; Alcotest.test_case "passes through when no panic" `Quick recovery_passes_through ])
    ; ("request_logger",
       [ Alcotest.test_case "captures status" `Quick request_logger_captures_status
       ; Alcotest.test_case "works with auth" `Quick request_logger_works_with_auth ])
    ; ("api_key_auth",
       [ Alcotest.test_case "missing key refused" `Quick api_key_auth_missing
       ; Alcotest.test_case "wrong key refused" `Quick api_key_auth_wrong
       ; Alcotest.test_case "correct key allowed" `Quick api_key_auth_correct ])
    ; ("hardening",
       [ Alcotest.test_case "max header bytes configured" `Quick max_header_bytes_configured
       ; Alcotest.test_case "max header bytes rejects oversized headers" `Quick max_header_bytes_rejects_oversized
       ; Alcotest.test_case "max header bytes allows normal headers" `Quick max_header_bytes_allows_normal ]) ]