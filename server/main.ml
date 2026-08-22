(* products-api executable — entry point and startup orchestration.
   Startup order mirrors Go: parse flags+env → resolve → validate (catalog load
   fail-fast → api-key required → listen address) → bind Dream. The catalog is
   loaded once at startup and held in memory for [GET /products], matching Go's
   package-level slice. *)

open Apicommand
open Server_lib

let () =
  match Cli.parse () with
  | Error e -> Fmt.epr "%a@." Cli.pp_error e; exit 1
  | Ok cfg ->
    (* [validate] already loaded the catalog; reload here for the in-memory
       copy (the validate call is a fail-fast check, this one is the value). *)
    let catalog =
      match Catalog.load_catalog ~path:cfg.catalog with
      | Ok c -> c
      | Error e -> Fmt.epr "products API: load catalog: %s@." e; exit 1
    in
    let logger = Log.create ~out:stdout () in
    (* Split Go's ["host:port"] addr into Dream's interface + port. *)
    let host, port =
      match String.rindex_opt cfg.addr ':' with
      | Some i ->
        (String.sub cfg.addr 0 i,
         int_of_string (String.sub cfg.addr (i + 1)
                          (String.length cfg.addr - i - 1)))
      | None -> Fmt.epr "products API: invalid listen address: %s@." cfg.addr; exit 1
    in
    let tls = cfg.tls_cert <> "" || cfg.tls_key <> "" in
    if tls && (cfg.tls_cert = "" || cfg.tls_key = "") then begin
      Fmt.epr "products API: --tls-cert and --tls-key must be set together to enable TLS@.";
      exit 1
    end;
    Log.info logger "products API starting"
      [ "addr", S cfg.addr; "tls", S (string_of_bool tls) ];
    let handler = Server.app ~catalog ~api_key:cfg.api_key ~logger in
    Dream.run
      ~interface:host
      ~port
      ~tls
      ?certificate_file:(if tls then Some cfg.tls_cert else None)
      ?key_file:(if tls then Some cfg.tls_key else None)
      ~greeting:false ~builtins:false
      handler