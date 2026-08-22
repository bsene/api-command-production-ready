(* Bootstrap entry point for the OCaml Lambda (custom runtime [provided.al2023]).
   Mirrors Go [main] in [infra/lambda/main.go]: JSON slog logger, load the
   catalog from [CATALOG_PATH] (default [/opt/catalog/products.json], non-fatal
   on miss), read [LAMBDA_API_KEY], then enter the Runtime API loop. *)

open Apicommand
open Lambda_lib

let catalog_path () =
  match Sys.getenv_opt "CATALOG_PATH" with
  | Some p when p <> "" -> p
  | _ -> "/opt/catalog/products.json"

let () =
  let logger = Log.create ~out:stdout () in
  let catalog =
    match Catalog.load_catalog ~path:(catalog_path ()) with
    | Ok c -> c
    | Error e ->
      Log.warn logger "could not load catalog — serving empty catalog"
        [ "path", S (catalog_path ()); "error", S e ];
      []
  in
  let api_key =
    match Sys.getenv_opt "LAMBDA_API_KEY" with Some k -> k | None -> ""
  in
  let api =
    try Runtime.runtime_api ()
    with Failure _ ->
      Log.error logger "AWS_LAMBDA_RUNTIME_API not set — exiting" [];
      exit 1
  in
  let rate_limit = Lambda_lib.Rate_limit.create () in
  Log.info logger "lambda bootstrap starting"
    [ "catalog", S (catalog_path ()); "entries", I (List.length catalog) ];
  Lwt_main.run (Runtime.run ~api ~api_key ~catalog ~rate_limit ~logger)