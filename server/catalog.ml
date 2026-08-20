(* Catalog loading — port of [loadCatalog] in cmd/products-api/main.go.
   Reads the whole file into a buffer then hands the bytes to [Wire.decode].
   [Wire.decode_products] preserves array order, so the positional contract
   the Hurl smoke tests rely on (idx0..idx15) holds end-to-end. *)

open Apicommand

let read_file path =
  let ch = open_in path in
  let buf = Buffer.create 4096 in
  (try
     while true do
       Buffer.add_channel buf ch 4096
     done
   with End_of_file -> ());
  close_in ch;
  Buffer.contents buf

let load_catalog ~path =
  try
    let s = read_file path in
    Wire.decode_products s
  with Sys_error msg -> Error msg