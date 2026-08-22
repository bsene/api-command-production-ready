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