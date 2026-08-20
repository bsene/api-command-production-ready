(** Dream HTTP app — OCaml port of the server, middleware chain, and hardening
    in [cmd/products-api/main.go]. Middleware composition is outermost-first
    ([request_logger] → [recover] → [security_headers] → [api_key_auth] →
    router), matching Go's [chain]. Middlewares are exposed individually so the
    white-box tests can exercise them in isolation, as the Go tests do. *)

open Apicommand

(** Configured [MaxHeaderBytes] cap (Go's [1 << 20]). Dream exposes no
    per-server header-size limit, so this is the asserted constant (A05). *)
val max_header_bytes : int

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