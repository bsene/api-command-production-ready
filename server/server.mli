(** Dream HTTP app — server, middleware chain, and hardening.
    Middleware composition is outermost-first
    ([request_logger] → [recover] → [enforce_max_header_bytes] →
    [security_headers] → [api_key_auth] → router), matching the [chain] order.
    Middlewares are exposed individually so the white-box tests can exercise
    them in isolation. *)

open Apicommand

(** Configured [MaxHeaderBytes] cap (Go's [1 << 20]). Dream exposes no
    per-server header-size limit, so this is the asserted constant (A05). *)
val max_header_bytes : int

(** [enforce_max_header_bytes] rejects requests whose total header bytes exceed
    [max_header_bytes] with [431 Request Header Fields Too Large] (A05). *)
val enforce_max_header_bytes : Dream.middleware

(** [products_handler catalog] serves the catalog as JSON on [GET /products]
    (Content-Type [application/json], positional order preserved). *)
val products_handler : Product.product list -> Dream.handler

(** [api_key_auth key] rejects requests whose [x-api-key] header does not
    constant-time-match [key] with a 401 ([WWW-Authenticate: ApiKey]). *)
val api_key_auth : string -> Dream.middleware

(** [security_headers] sets the baseline defensive headers (A02/A05); HSTS only
    over TLS. *)
val security_headers : Dream.middleware

(** [recover logger] catches exceptions from downstream and returns a clean 500
    (A05). *)
val recover : Log.t -> Dream.middleware

(** [request_logger logger] logs method/path/status/remote/elapsed_ms (A09). *)
val request_logger : Log.t -> Dream.middleware

(** [app ~catalog ~api_key ~logger] is the full wired handler (chain + router),
    ready for [Dream.run] or [Dream.test]. *)
val app :
  catalog:Product.product list -> api_key:string -> logger:Log.t -> Dream.handler