(* Lambda custom-runtime loop — OCaml port of the provided.al2023 event poll.
   AWS Lambda sets [AWS_LAMBDA_RUNTIME_API] to a host:port serving the Runtime
   API. The loop forever: GET [/runtime/invocation/next] (blocks until an
   invocation arrives), dispatch the decoded event to [Lambda_handler.handle],
   then POST the encoded response to [/runtime/invocation/<id>/response], or
   [/runtime/invocation/<id>/error] if the handler raised. Cohttp-lwt-unix is
   the HTTP client; the loop is split so [serve_one] (one iteration) is
   testable against a stub Runtime API without a real Lambda. *)

open Apicommand

type invocation = {
  request_id : string;
  event : Event.event;
}

let runtime_api () =
  match Sys.getenv_opt "AWS_LAMBDA_RUNTIME_API" with
  | Some api when api <> "" -> api
  | _ -> failwith "AWS_LAMBDA_RUNTIME_API not set"

(* [snippet s n] returns the first [n] bytes of [s] with an ellipsis when
   truncated — keeps the diagnostic log line bounded. *)
let snippet ?(max_len = 256) s =
  let len = String.length s in
  if len <= max_len then s else String.sub s 0 max_len ^ "…"

(* [next_invocation ~logger api] GETs the next event. The Runtime API blocks
   the response until an invocation is available, so this call is long-lived.

   On a headerless response (a non-2xx from Rapid — wrong base path, trailing
   slash in [AWS_LAMBDA_RUNTIME_API], or an init-phase error) we log the HTTP
   status, the headers actually received, and a body snippet *before* failing.
   Without this the bare [failwith] masks the trigger, turning a permanent
   Runtime-API misconfig into an opaque timeout. *)
let next_invocation ~logger api =
  let uri = Uri.of_string ("http://" ^ api ^ "/runtime/invocation/next") in
  let%lwt resp, body = Cohttp_lwt_unix.Client.get uri in
  let headers = Cohttp.Response.headers resp in
  let%lwt raw = Cohttp_lwt.Body.to_string body in
  let request_id =
    match Cohttp.Header.get headers "lambda-runtime-aws-request-id" with
    | Some v -> v
    | None ->
      Log.error logger "next_invocation: no request-id header"
        [ "status", I (Cohttp.Code.code_of_status (Cohttp.Response.status resp));
          "headers", S (Cohttp.Header.to_string headers);
          "body", S (snippet raw) ];
      failwith "missing Lambda-Runtime-Aws-Request-Id header"
  in
  let event =
    match Event.of_json raw with
    | Ok e -> e
    | Error msg -> failwith ("invalid runtime event: " ^ msg)
  in
  Lwt.return { request_id; event }

(* [post] POSTs and discards the response (Runtime API returns 202). *)
let post api path body_str =
  let uri = Uri.of_string ("http://" ^ api ^ path) in
  let body = Cohttp_lwt.Body.of_string body_str in
  let%lwt _resp, _body = Cohttp_lwt_unix.Client.post ~body uri in
  Cohttp_lwt.Body.drain_body _body

(* [response_to_json r] serializes an APIGW v2 response: the
   [{statusCode,headers,body}] object the Runtime API hands back to the
   Function URL. *)
let response_to_json (r : Event.response) =
  `Assoc
    [
      ("statusCode", `Int r.Event.status_code);
      ("headers", `Assoc (List.map (fun (k, v) -> (k, `String v)) r.Event.headers));
      ("body", `String r.Event.body);
    ]
  |> Yojson.Safe.to_string

let error_to_json msg =
  `Assoc [ ("errorMessage", `String msg) ] |> Yojson.Safe.to_string

(* [serve_one] runs exactly one invocation. The handler is pure and returns a
   response for every branch, so the error path only fires if [handle] itself
   raises (defensive — Go returns nil error). *)
let serve_one ~api ~api_key ~catalog ~rate_limit ~logger =
  let%lwt inv = next_invocation ~logger api in
  Lwt.catch
    (fun () ->
      let response =
        Lambda_handler.handle ~logger ~api_key ~catalog ~rate_limit inv.event
      in
      post api ("/runtime/invocation/" ^ inv.request_id ^ "/response")
        (response_to_json response))
    (fun exn ->
      let msg = Printexc.to_string exn in
      Log.error logger "invocation failed" [ "request_id", S inv.request_id; "error", S msg ];
      post api ("/runtime/invocation/" ^ inv.request_id ^ "/error") (error_to_json msg))

(* [run] is the forever loop. Unlike [serve_one], the whole iteration —
   including [next_invocation]'s fetch — is guarded: a transient Runtime API
   error (connection refused, reset) is logged and retried after a short
   backoff rather than letting the exception escape [Lwt_main.run] and killing
   the process. [serve_one] stays unguarded so a single iteration can be
   tested against a stub Runtime API. *)
let run ~api ~api_key ~catalog ~rate_limit ~logger =
  let rec loop () =
    let%lwt () =
      Lwt.catch
        (fun () -> serve_one ~api ~api_key ~catalog ~rate_limit ~logger)
        (fun exn ->
          let msg = Printexc.to_string exn in
          Log.error logger "runtime loop error — retrying in 1s"
            [ "error", S msg ];
          let%lwt () = Lwt_unix.sleep 1.0 in
          Lwt.return ())
    in
    loop ()
  in
  loop ()