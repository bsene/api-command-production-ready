(* OrdersManager — port of orders_manager.go. Fetches products from the
   products API via an injectable HTTP backend (so tests can substitute a
   fake transport, mirroring Go's [fakeTransport] / [WithHTTPClient]), then
   answers description/availability/search/cart-validation queries.

   SSRF scheme + IP-literal validation is delegated to [Ssrf] (port of
   checkSSRFIP / validateBaseURL). The real SSRF-safe cohttp dialer lands at
   G2 (Cohttp_backend); here we only need the abstraction + the logic. *)

open Product

(** An HTTP backend issues one GET and yields a [response] or a transport
    error. [response] is abstract and read back via the [status]/[body]
    accessors, so the manager never builds a backend-specific value — only
    the backend does. Production: SSRF-safe Cohttp_backend; tests:
    Fake_transport. *)
module type HTTP_BACKEND = sig
  type response
  val request :
    method_:string -> url:string -> headers:(string * string) list ->
    (response, string) result Lwt.t
  val status : response -> int
  val body : response -> string
end

(** A product matching a keyword search, with availability and price. *)
type search_result = { ref : int; description : string; available : bool; price : float }

(** An orders manager. Abstract: configure via [create], inspect via the
    accessors below. *)
type orders_manager

(** Create a manager targeting [base_url].

    The base URL MUST use https unless [allow_insecure_http] is set (local-dev
    fixture only); the host is validated against blocked IP ranges
    (loopback/private/link-local/metadata) at construction time. Hostnames are
    checked at dial time (G2 Cohttp_backend).

    [http_client] defaults to a stub that errors if called — every caller that
    actually fetches must inject a real backend (production: Cohttp_backend;
    tests: Fake_transport), mirroring Go where [WithHTTPClient] is the tested
    path.

    [allow_insecure_http] is the same "local dev / insecure transport" opt-in
    as [Cohttp_backend.make]'s [~allow_local_dev]: when injecting a
    [Cohttp_backend], its [allow_local_dev] MUST match [allow_insecure_http].
    A mismatch (e.g. [allow_local_dev:true] with [allow_insecure_http:false])
    would let a hostname URL resolve to a loopback/private IP and be dialed,
    silently bypassing the construction-time SSRF check. *)
val create :
  base_url:string ->
  ?http_client:(module HTTP_BACKEND) ->
  ?allow_insecure_http:bool ->
  ?api_key:string ->
  ?logger:Log.t ->
  ?timeout_ms:float ->
  unit ->
  (orders_manager, string) result

val base_url : orders_manager -> string
val set_logger : orders_manager -> Log.t -> unit

val all_descriptions : orders_manager -> (string list, string) result Lwt.t
val available_descriptions : orders_manager -> (string list, string) result Lwt.t
val is_available : orders_manager -> int -> (bool, string) result Lwt.t
val search : orders_manager -> string -> (search_result list, string) result Lwt.t

(** Validate a cart. Returns [Ok {valid=true; total_price}] when every item is
    available in the requested quantity, otherwise
    [Error (`Invalid_cart _)]. A fetch failure surfaces as
    [`Fetch _] (the Go code returns the plain fetch error from the same
    call). Zero/negative quantities are rejected before stock is consulted so
    a negative quantity can never reduce the total (A04). *)
val validate_cart :
  orders_manager ->
  cart_item list ->
  (cart_validation, [> `Invalid_cart of invalid_cart_error | `Fetch of string]) result Lwt.t