(* Lambda custom-runtime loop — OCaml port of the provided.al2023 event poll.
   AWS Lambda sets [AWS_LAMBDA_RUNTIME_API] to a host:port serving the Runtime
   API. The loop forever: GET [/runtime/invocation/next] (blocks until an
   invocation arrives), dispatch the decoded event to [Lambda_handler.handle],
   then POST the encoded response to [/runtime/invocation/<id>/response], or
   [/runtime/invocation/<id>/error] if the handler raised. Cohttp-lwt-unix is
   the HTTP client; the loop is split so [serve_one] (one iteration) is
   testable against a stub Runtime API without a real Lambda. *)

open Apicommand

(* [api_version] is the Runtime-API version path prefix the Lambda Runtime API
   expects on every path (e.g. [/2018-06-01/runtime/invocation/next]). The
   version is optional in the spec, but the reference runtime (anmonteiro/
   aws-lambda-ocaml-runtime) and the AWS docs both send it, so we match. *)
let api_version = "2018-06-01"

type invocation = {
  request_id : string;
  event : Event.event;
  context : Lambda_handler.context;
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
  let uri = Uri.of_string ("http://" ^ api ^ "/" ^ api_version ^ "/runtime/invocation/next") in
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
  (* Best-effort capture of the remaining invocation headers. Only
     [request_id] stays hard-required (the headerless-404 diagnostic relies on it
     firing first); the rest default so a real Lambda invocation — which always
     sends them — surfaces arn/deadline/trace to the handler. *)
  let invoked_function_arn =
    match Cohttp.Header.get headers "lambda-runtime-invoked-function-arn" with
    | Some v -> v
    | None -> ""
  in
  let deadline_ms =
    match Cohttp.Header.get headers "lambda-runtime-deadline-ms" with
    | Some s -> (try Some (Int64.of_string s) with _ -> None)
    | None -> None
  in
  let trace_id = Cohttp.Header.get headers "lambda-runtime-trace-id" in
  let event =
    match Event.of_json raw with
    | Ok e -> e
    | Error msg -> failwith ("invalid runtime event: " ^ msg)
  in
  let context = { Lambda_handler.invoked_function_arn; deadline_ms; trace_id } in
  Lwt.return { request_id; event; context }

(* [post] POSTs and discards the response (Runtime API returns 202). [headers]
   defaults to [] for the response path; the error path passes
   [application/vnd.aws.lambda.error+json] + the [Lambda-Runtime-Function-Error-Type]
   header, matching the AWS custom-runtime error protocol. *)
let post ?(headers = []) api path body_str =
  let uri = Uri.of_string ("http://" ^ api ^ path) in
  let body = Cohttp_lwt.Body.of_string body_str in
  let%lwt _resp, _body =
    Cohttp_lwt_unix.Client.post ~headers:(Cohttp.Header.of_list headers) ~body uri
  in
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

let error_to_json ?(error_type = "Unhandled") msg =
  `Assoc [ ("errorMessage", `String msg); ("errorType", `String error_type) ]
  |> Yojson.Safe.to_string

(* [serve_one] runs exactly one invocation. The handler is pure and returns a
   response for every branch, so the error path only fires if [handle] itself
   raises (defensive — Go returns nil error). The response POST carries
   [application/json]; the error POST carries the Lambda error content-type and
   [Lambda-Runtime-Function-Error-Type] header, matching the reference runtime. *)
let serve_one ~api ~api_key ~catalog ~rate_limit ~logger =
  let%lwt inv = next_invocation ~logger api in
  Lwt.catch
    (fun () ->
      let response =
        Lambda_handler.handle ~logger ~api_key ~catalog ~rate_limit ~context:inv.context inv.event
      in
      post api
        ("/" ^ api_version ^ "/runtime/invocation/" ^ inv.request_id ^ "/response")
        ~headers:[ "Content-Type", "application/json" ]
        (response_to_json response))
    (fun exn ->
      let msg = Printexc.to_string exn in
      Log.error logger "invocation failed" [ "request_id", S inv.request_id; "error", S msg ];
      post api
        ("/" ^ api_version ^ "/runtime/invocation/" ^ inv.request_id ^ "/error")
        ~headers:
          [ "Content-Type", "application/vnd.aws.lambda.error+json"
          ; "Lambda-Runtime-Function-Error-Type", "Unhandled"
          ]
        (error_to_json msg))

(* [max_consecutive_failures] caps how many iterations in a row may fail before
   the loop gives up. Without it a *permanent* error (a headerless `/next`
   response — see [next_invocation]) is retried like a transient one forever,
   burning the whole Lambda init/invoke budget as an opaque timeout. Hitting the
   cap exits the process so Lambda records a legible error instead. *)
let max_consecutive_failures = 5

(* [post_init_error] reports a fatal runtime error to the Runtime-API init-error
   endpoint so Lambda records a legible init error rather than a bare process
   exit. Best-effort: the cap fires precisely when we may be unable to reach the
   Runtime API at all, so callers ignore the result (matching the reference
   runtime's "report then fail" behaviour). *)
let post_init_error api msg =
  post api ("/" ^ api_version ^ "/runtime/init/error")
    ~headers:
      [ "Content-Type", "application/vnd.aws.lambda.error+json"
      ; "Lambda-Runtime-Function-Error-Type", "Unhandled"
      ]
    (error_to_json msg)

(* [run] is the forever loop. Unlike [serve_one], the whole iteration —
   including [next_invocation]'s fetch — is guarded: a transient Runtime API
   error (connection refused, reset) is logged and retried after a short
   backoff rather than letting the exception escape [Lwt_main.run] and killing
   the process. [serve_one] stays unguarded so a single iteration can be
   tested against a stub Runtime API. Consecutive failures are counted; on
   reaching [max_consecutive_failures] [on_cap] is called (default: [exit 1])
   so the bootstrap exits rather than spin until the Lambda timeout. Pass
   [~on_cap] to override the exit behaviour (e.g. raise an exception in tests). *)
let run ?(on_cap = (fun () -> exit 1)) ~api ~api_key ~catalog ~rate_limit ~logger () =
  (* [loop failures] returns [failures'] — the count to carry into the next
     iteration. A successful iteration resets it to 0; a failed one increments
     and (if under the cap) sleeps then retries with the bumped count. Threading
     the count through [failures'] (not a fixed [loop 0]) is what makes the cap
     actually trip — otherwise the count resets every iteration and the loop
     spins forever, which is the bug this cap exists to kill. *)
  let rec loop failures =
    let%lwt failures' =
      Lwt.catch
        (fun () ->
          let%lwt () = serve_one ~api ~api_key ~catalog ~rate_limit ~logger in
          Lwt.return 0)
        (fun exn ->
          let msg = Printexc.to_string exn in
          let failures' = failures + 1 in
          Log.error logger "runtime loop error — retrying in 1s"
            [ "error", S msg; "consecutive_failures", I failures' ];
          if failures' >= max_consecutive_failures then begin
            Log.error logger "runtime loop: too many consecutive failures — exiting"
              [ "max", I max_consecutive_failures ];
            let%lwt () =
              Lwt.catch
                (fun () -> post_init_error api "runtime loop: too many consecutive failures")
                (fun _ -> Lwt.return ())
            in
            on_cap ();
            Lwt.return failures'
          end
          else begin
            let%lwt () = Lwt_unix.sleep 1.0 in
            Lwt.return failures'
          end)
    in
    loop failures'
  in
  loop 0