(** CLI configuration — OCaml port of the flag/env parsing in
    [cmd/products-api/main.go]. Flags fall back to env vars exactly as Go's
    [envOr] does: an empty [-api-key] flag reads [PRODUCTS_API_KEY]; an empty
    [-catalog] flag reads [PRODUCTS_CATALOG], then defaults to the shared
    fixture [infra/catalog/products.json]. *)

(** Resolved startup configuration. *)
type config = {
  addr : string;
  catalog : string;
  api_key : string;
  allow_external : bool;
  tls_cert : string;
  tls_key : string;
}

(** Startup validation error, in Go's check order: catalog first (fail fast),
    then api-key, then listen address. *)
type error =
  | No_api_key
  | Bad_addr of string
  | Bad_catalog of string

val pp_error : error Fmt.t

(** [env_or ?env name fallback] is [env name] with a fallback — port of Go's
    [envOr] (which uses [os.LookupEnv], so a set-empty var yields [""]). [env]
    defaults to [Sys.getenv_opt] and is injectable so tests can drive the
    fallback without mutating the process environment. *)
val env_or : ?env:(string -> string option) -> string -> string -> string

(** [resolve ?env] applies the flag-then-env fallback to the raw flag values
    and returns the resolved [config]. Pure (no I/O), so it is the unit under
    test for env-fallback behaviour. *)
val resolve :
  addr:string -> catalog:string -> api_key:string ->
  allow_external:bool -> tls_cert:string -> tls_key:string ->
  ?env:(string -> string option) -> unit ->
  config

(** [validate cfg] mirrors Go startup ordering: load the catalog (fail fast),
    then require a non-empty api key, then validate the listen address. *)
val validate : config -> (unit, error) result

(** [parse ?argv ?env ()] runs the cmdliner term (flags), resolves env
    fallbacks via [env] (default [Sys.getenv_opt]), then validates. Returns
    [Ok cfg] or the first [error]. [--help]/[--version] are handled by cmdliner
    (printed, then mapped to [Error No_api_key] since no server config was
    produced). *)
val parse : ?argv:string array -> ?env:(string -> string option) -> unit -> (config, error) result