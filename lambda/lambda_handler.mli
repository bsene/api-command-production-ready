(** Pure Lambda handler — OCaml port of [handle] in [infra/lambda/main.go].
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

(** [handle ~logger ~api_key ~catalog ~rate_limit event] checks the per-IP
    rate limit (A05, before auth), authenticates via [x-api-key], serves
    [GET /products] from [catalog], and otherwise echoes availability. Every
    branch returns an {!Event.response}; error bodies match Go's exact strings. *)
val handle :
  logger:Log.t ->
  api_key:string ->
  catalog:Product.product list ->
  rate_limit:Rate_limit.t ->
  Event.event ->
  Event.response