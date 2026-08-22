(** Lambda custom-runtime loop — the [provided.al2023] event poll, ported from
    the Go [lambda.Start] entry point. [AWS_LAMBDA_RUNTIME_API] is the host:port
    of the Runtime API. *)

open Apicommand

(** One invocation pulled from [/runtime/invocation/next]. [context] carries the
    best-effort Runtime-API headers (arn, deadline, trace) surfaced to the
    handler. *)
type invocation = {
  request_id : string;
  event : Event.event;
  context : Lambda_handler.context;
}

(** [runtime_api ()] reads [AWS_LAMBDA_RUNTIME_API], failing if unset. *)
val runtime_api : unit -> string

(** [next_invocation ~logger api] GETs the next event from the Runtime API
    (blocks until one is available). On a headerless (non-2xx) response the HTTP
    status, headers, and a body snippet are logged before failing, so the
    trigger is visible rather than an opaque [missing header] error. *)
val next_invocation : logger:Log.t -> string -> invocation Lwt.t

(** [post api path body] POSTs [body] to {api}{path}. [headers] defaults to []
    for the response path; the error/init-error paths pass the Lambda error
    content-type and [Lambda-Runtime-Function-Error-Type] header. *)
val post : ?headers:(string * string) list -> string -> string -> string -> unit Lwt.t

(** [response_to_json r] encodes an APIGW v2 response for the Runtime API. *)
val response_to_json : Event.response -> string

(** [serve_one ~api ~api_key ~catalog ~rate_limit ~logger] processes exactly
    one invocation: fetch, handle, POST the response (or an error). Exposed
    for in-process testing against a stub Runtime API. *)
val serve_one :
  api:string ->
  api_key:string ->
  catalog:Product.product list ->
  rate_limit:Rate_limit.t ->
  logger:Log.t ->
  unit Lwt.t

(** [run] is the forever loop. Consecutive failures are counted; on reaching
    {!max_consecutive_failures} [on_cap] is called. The default [on_cap] is
    [exit 1], so in production the bootstrap exits and Lambda records a legible
    error instead of spinning until the timeout. A successful iteration resets
    the counter to 0. Pass [~on_cap] to override the exit behaviour (e.g. in
    tests, raise an exception to catch the cap instead of killing the process). *)
val run :
  ?on_cap:(unit -> unit) ->
  api:string ->
  api_key:string ->
  catalog:Product.product list ->
  rate_limit:Rate_limit.t ->
  logger:Log.t ->
  unit ->
  unit Lwt.t

(** The maximum number of consecutive failures before [run] gives up. *)
val max_consecutive_failures : int
