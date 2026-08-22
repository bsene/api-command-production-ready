(* CLI configuration — flag/env parsing for the products-api executable.
   [resolve] is the pure, testable core (flag-then-env fallback); [parse]
   wraps it in a cmdliner term for the executable. [validate] reproduces Go's
   startup check order: catalog load (fail fast) → api-key required → listen
   address. *)

open Apicommand

let env_or ?(env = Sys.getenv_opt) name fallback =
  match env name with Some v -> v | None -> fallback

type config = {
  addr : string;
  catalog : string;
  api_key : string;
  allow_external : bool;
  tls_cert : string;
  tls_key : string;
}

type error =
  | No_api_key
  | Bad_addr of string
  | Bad_catalog of string

let pp_error ppf = function
  | No_api_key ->
    Fmt.pf ppf
      "products API: -api-key (or PRODUCTS_API_KEY) is required; pass -api-key or set PRODUCTS_API_KEY"
  | Bad_addr msg -> Fmt.pf ppf "products API: invalid listen address: %s" msg
  | Bad_catalog msg -> Fmt.pf ppf "products API: load catalog: %s" msg

(* Apply the flag-then-env fallback to an already-built config. [env] is
   injectable so tests can drive the fallback without mutating the process
   environment (which OCaml cannot unset — [Unix.putenv x ""] sets empty, it
   does not remove the binding, and Go's [os.LookupEnv] treats a set-empty
   var as present with value [""]). *)
let resolve_cfg ?(env = Sys.getenv_opt) c =
  let api_key =
    if c.api_key = "" then env_or ~env "PRODUCTS_API_KEY" "" else c.api_key
  in
  let catalog =
    if c.catalog = "" then env_or ~env "PRODUCTS_CATALOG" "infra/catalog/products.json"
    else c.catalog
  in
  { c with api_key; catalog }

let resolve ~addr ~catalog ~api_key ~allow_external ~tls_cert ~tls_key
    ?(env = Sys.getenv_opt) () =
  resolve_cfg ~env
    { addr; catalog; api_key; allow_external; tls_cert; tls_key }

let validate cfg =
  (* Go loads the catalog before checking the api key so a malformed fixture
     fails fast. Mirror that order. *)
  match Catalog.load_catalog ~path:cfg.catalog with
  | Error e -> Error (Bad_catalog e)
  | Ok _ ->
    if cfg.api_key = "" then Error No_api_key
    else
      (match Ssrf.validate_listen_addr cfg.addr cfg.allow_external with
       | Error e -> Error (Bad_addr e)
       | Ok () -> Ok ())

(* --- cmdliner term ------------------------------------------------------- *)

open Cmdliner

let addr_arg =
  Arg.(value & opt string "127.0.0.1:18080" &
       info ~docv:"ADDR" ~doc:"listen address" [ "addr" ])

let catalog_arg =
  Arg.(value & opt string "" &
       info ~docv:"PATH"
         ~doc:"path to the catalog JSON file; defaults to $PRODUCTS_CATALOG \
               then to infra/catalog/products.json"
         [ "catalog" ])

let api_key_arg =
  Arg.(value & opt string "" &
       info ~docv:"KEY"
         ~doc:"API key required in the x-api-key header; falls back to \
               $PRODUCTS_API_KEY"
         [ "api-key" ])

let allow_external_arg =
  Arg.(value & flag &
       info ~doc:"allow binding to a non-loopback address" [ "allow-external" ])

let tls_cert_arg =
  Arg.(value & opt string "" &
       info ~docv:"PATH" ~doc:"path to TLS certificate" [ "tls-cert" ])

let tls_key_arg =
  Arg.(value & opt string "" &
       info ~docv:"PATH" ~doc:"path to TLS private key" [ "tls-key" ])

(* The term produces the RAW flag values; env fallback is applied in [parse]
   after evaluation so a single [resolve_cfg] serves both paths. *)
let make addr catalog api_key allow_external tls_cert tls_key : config =
  { addr; catalog; api_key; allow_external; tls_cert; tls_key }

let config_term =
  Term.(const make $ addr_arg $ catalog_arg $ api_key_arg
        $ allow_external_arg $ tls_cert_arg $ tls_key_arg)

let cmd =
  Cmd.v
    (Cmd.info "products-api" ~doc:"products API server"
       ~man:[ `S "DESCRIPTION";
              `P "Serves the product catalog on GET /products, protected by an \
                  x-api-key header." ])
    config_term

let parse ?argv ?(env = Sys.getenv_opt) () =
  match Cmd.eval_value ?argv cmd with
  | Ok (`Ok raw) ->
    let cfg = resolve_cfg ~env raw in
    (match validate cfg with Ok () -> Ok cfg | Error e -> Error e)
  | Ok `Version | Ok `Help | Error _ -> Error No_api_key