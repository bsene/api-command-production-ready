(* Structured logger emitting Go slog text-handler format.
   Format: level=<LVL> msg="<msg>" k1=v1 k2=v2 ... — matching the substring
   assertions in orders_manager_test.go (level=INFO/WARN/ERROR, status=N,
   invalid_count=N, the message text).

   By default a logger writes only into an in-memory buffer, so white-box
   tests can assert on [contents]. Production entry points (the local server
   and the Lambda bootstrap) pass [~out:stdout] so the same lines reach the
   process stdout — CloudWatch for Lambda, the console for the server —
   preserving Go slog's stdout-sink behaviour. The buffer is always kept, so
   [contents] keeps working regardless of whether an [out] channel is set. *)

type value =
  | S of string
  | I of int
  | F of float

type t = { buf : Buffer.t; out : out_channel option }

let create ?out () = { buf = Buffer.create 512; out }
let contents t = Buffer.contents t.buf

(* True when s contains a character that could break the `k=v` line format or
   inject a fake field — in which case we quote+escape the value. Clean
   strings (URLs, hostnames, refs without spaces) stay bare to match the
   slog text-handler format the tests assert on. *)
let needs_quoting s =
  let n = String.length s in
  let rec go i =
    if i >= n then false
    else match String.unsafe_get s i with
    | ' ' | '=' | '"' | '\\' | '\n' | '\r' | '\t' -> true
    | c when Char.code c < 0x20 -> true
    | _ -> go (i + 1)
  in
  go 0

let escape_string s =
  if not (needs_quoting s) then s
  else begin
    let b = Buffer.create (String.length s + 2) in
    Buffer.add_char b '"';
    String.iter (fun c ->
      (match c with
       | '"' -> Buffer.add_string b "\\\""
       | '\\' -> Buffer.add_string b "\\\\"
       | '\n' -> Buffer.add_string b "\\n"
       | '\r' -> Buffer.add_string b "\\r"
       | '\t' -> Buffer.add_string b "\\t"
       | c when Char.code c < 0x20 -> Buffer.add_string b (Printf.sprintf "\\x%02x" (Char.code c))
       | c -> Buffer.add_char b c)) s;
    Buffer.add_char b '"';
    Buffer.contents b
  end

let value_str = function
  | S s -> escape_string s
  | I n -> string_of_int n
  | F f -> string_of_float f

let level_str = function `Info -> "INFO" | `Warn -> "WARN" | `Error -> "ERROR"

let log t lvl msg kvs =
  let line = Buffer.create 256 in
  Buffer.add_string line (Printf.sprintf "level=%s msg=\"%s\"" (level_str lvl) msg);
  List.iter (fun (k, v) ->
    Buffer.add_string line (Printf.sprintf " %s=%s" k (value_str v))) kvs;
  Buffer.add_char line '\n';
  let s = Buffer.contents line in
  Buffer.add_string t.buf s;
  match t.out with
  | Some ch -> output_string ch s; flush ch
  | None -> ()

let info t msg kvs = log t `Info msg kvs
let warn t msg kvs = log t `Warn msg kvs
let error t msg kvs = log t `Error msg kvs