(* Structured logger emitting Go slog text-handler format into a buffer.
   Format: level=<LVL> msg="<msg>" k1=v1 k2=v2 ... — matching the substring
   assertions in orders_manager_test.go (level=INFO/WARN/ERROR, status=N,
   invalid_count=N, the message text). *)

type value =
  | S of string
  | I of int
  | F of float

type t = { buf : Buffer.t }

let create () = { buf = Buffer.create 512 }
let contents t = Buffer.contents t.buf

let value_str = function S s -> s | I n -> string_of_int n | F f -> string_of_float f

let level_str = function `Info -> "INFO" | `Warn -> "WARN" | `Error -> "ERROR"

let log t lvl msg kvs =
  let b = t.buf in
  Buffer.add_string b (Printf.sprintf "level=%s msg=\"%s\"" (level_str lvl) msg);
  List.iter (fun (k, v) ->
    Buffer.add_string b (Printf.sprintf " %s=%s" k (value_str v))) kvs;
  Buffer.add_char b '\n'

let info t msg kvs = log t `Info msg kvs
let warn t msg kvs = log t `Warn msg kvs
let error t msg kvs = log t `Error msg kvs