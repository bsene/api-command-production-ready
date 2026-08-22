(* Alcotest suite for the Lambda runtime-loop diagnostics + retry cap.

   Two scenarios against a stub Runtime-API server that always returns a
   headerless 404 (mimicking a broken/wrong Runtime API base path):

   1. "diagnostic" — [next_invocation] logs the HTTP status, headers, and body
      snippet BEFORE failing, so the trigger is visible (root-cause Fix 1).
      Asserts the log buffer contains the error message, status=404, and the
      body snippet.

   2. "cap" — [run] trips [on_cap] after [max_consecutive_failures] (5)
      consecutive errors instead of spinning forever (root-cause Fix 2). The
      test passes [failwith] as [on_cap] so the cap surfaces as a catchable
      exception rather than killing the test process via [exit 1].

   The stub server is a raw [Lwt_unix] TCP socket — no Cohttp server
   dependency. It accepts a connection, drains the request, and writes a
   canned 404 with no Lambda-Runtime-Aws-Request-Id header. *)

open Apicommand
open Lambda_lib

(* --- helpers --------------------------------------------------------------- *)

let contains s sub =
  let n = String.length s and m = String.length sub in
  let rec go i =
    if i + m > n then false
    else if String.sub s i m = sub then true else go (i + 1)
  in
  if m = 0 then true else go 0

let check_sub name s sub =
  Alcotest.(check bool) name true (contains s sub)

(* --- stub Runtime-API server: always 404, no request-id header ------------- *)

(* [start_stub_server ~max_requests] binds a loopback TCP socket on an
   ephemeral port and starts an [Lwt.async] accept loop. Each accepted
   connection gets a canned 404 response with no Lambda-Runtime-Aws-Request-Id
   header and Connection: close. After [max_requests] connections the accept
   loop stops, so [Lwt_main.run] can return once the client side is done. *)

let stub_body = "RapidError: wrong base path\n"

let start_stub_server ~max_requests =
  let sock = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt sock Unix.SO_REUSEADDR true;
  let%lwt () =
    Lwt_unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0))
  in
  Lwt_unix.listen sock 16;
  let port =
    match Lwt_unix.getsockname sock with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> 0
  in
  let response =
    Printf.sprintf
      "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\
       Content-Length: %d\r\nConnection: close\r\n\r\n%s"
      (String.length stub_body) stub_body
  in
  let remaining = ref max_requests in
  let rec serve () =
    if !remaining <= 0 then Lwt.return ()
    else begin
      let%lwt (conn, _) = Lwt_unix.accept sock in
      Lwt.async
        (fun () ->
          (* drain the request (one read is enough for a small GET) *)
          let buf = Bytes.create 4096 in
          let%lwt _n = Lwt_unix.read conn buf 0 4096 in
          let%lwt _w =
            Lwt_unix.write_string conn response 0 (String.length response)
          in
          Lwt_unix.close conn);
      decr remaining;
      serve ()
    end
  in
  Lwt.async serve;
  Lwt.return port

(* --- tests ----------------------------------------------------------------- *)

(* "diagnostic" — next_invocation logs before failing on a headerless 404. *)
let diagnostic_test () =
  let logger = Log.create () in
  Lwt_main.run
    (let%lwt port = start_stub_server ~max_requests:1 in
     let api = Printf.sprintf "127.0.0.1:%d" port in
     Lwt.catch
       (fun () ->
         let%lwt _inv = Runtime.next_invocation ~logger api in
         Lwt.return ())
       (fun _exn -> Lwt.return ()));
  let s = Log.contents logger in
  check_sub "logs error message" s "next_invocation: no request-id header";
  check_sub "logs status 404" s "status=404";
  check_sub "logs body snippet" s "RapidError"

(* "cap" — run trips [on_cap] after max_consecutive_failures (5) instead of
   spinning forever. The stub server always returns a headerless 404, so every
   iteration fails. After 5 consecutive failures (4 s of 1 s backoffs) [run]
   calls [on_cap]. The test passes [failwith] as [on_cap] so the cap surfaces as
   a catchable exception rather than killing the test process via [exit 1]. *)
let cap_test () =
  let logger = Log.create () in
  let cap_msg = "runtime loop cap reached" in
  let raised =
    try
      Lwt_main.run
        (let%lwt port = start_stub_server ~max_requests:10 in
         let api = Printf.sprintf "127.0.0.1:%d" port in
         Runtime.run ~api
           ~api_key:"test-key-at-least-32-characters-long"
           ~catalog:[] ~rate_limit:(Rate_limit.create ())
           ~on_cap:(fun () -> failwith cap_msg)
           ~logger ());
      false
    with Failure msg -> String.equal msg cap_msg
  in
  let s = Log.contents logger in
  check_sub "logs cap exit message"
    s "runtime loop: too many consecutive failures — exiting";
  check_sub "logs 5 consecutive failures" s "consecutive_failures=5";
  Alcotest.(check bool) "on_cap raised with cap message" true raised

let () =
  Alcotest.run "lambda-runtime"
    [ ( "runtime-loop",
        [ Alcotest.test_case "diagnostic" `Quick diagnostic_test
        ; Alcotest.test_case "cap" `Slow cap_test
        ] )
    ]
