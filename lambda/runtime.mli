(** Lambda custom-runtime loop — the [provided.al2023] event poll, ported from
    the Go [lambda.Start] entry point. [AWS_LAMBDA_RUNTIME_API] is the host:port
    of the Runtime API. *)

open Apicommand

(** One invocation pulled from [/runtime/invocation/next]. *)
type invocation = {
  request_id : string;
  event : Event.event;
}

(** [runtime_api ()] reads [AWS_LAMBDA_RUNTIME_API], failing if unset. *)
val runtime_api : unit -> string

(** [next_invocation api] GETs the next event from the Runtime API (blocks until
    one is available). *)
val next_invocation : string -> invocation Lwt.t

(** [post api path body] POSTs [body] to {api}{path}. *)
val post : string -> string -> string -> unit Lwt.t

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

(** [run] is the forever loop. *)
val run :
  api:string ->
  api_key:string ->
  catalog:Product.product list ->
  rate_limit:Rate_limit.t ->
  logger:Log.t ->
  unit Lwt.t