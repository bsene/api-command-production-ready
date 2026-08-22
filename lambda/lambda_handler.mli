(** Pure Lambda handler — the [handle] entry point.
    The API key and catalog are injected so the handler is testable in-process
    without package-level mutable state. *)

open Apicommand

(** The JSON request body (ref/description/stock/price), with zero defaults. *)
type request = {
  ref : int;
  description : string;
  stock : int;
  price : float;
}

(** Runtime-API invocation context surfaced to the handler. Captured from the
    [next]-response headers by [Runtime.next_invocation]. [invoked_function_arn]
    is logged on the failed-auth path; [deadline_ms] / [trace_id] are captured
    but not yet consumed (reserved for deadline-aware / trace-aware logic). *)
type context = {
  invoked_function_arn : string;  (** "" if the [Lambda-Runtime-Invoked-Function-Arn] header was absent *)
  deadline_ms : int64 option;     (** from [Lambda-Runtime-Deadline-Ms] *)
  trace_id : string option;        (** from [Lambda-Runtime-Trace-Id] *)
}

(** [handle ~logger ~api_key ~catalog ~rate_limit ~context event] authenticates via
    [x-api-key], then checks the global rate limit (A05) only on
    failed-authentication traffic, serves [GET /products] from [catalog], and
    otherwise echoes availability. Every branch returns an {!Event.response};
    error bodies match Go's exact strings. *)
val handle :
  logger:Log.t ->
  api_key:string ->
  catalog:Product.product list ->
  rate_limit:Rate_limit.t ->
  context:context ->
  Event.event ->
  Event.response
