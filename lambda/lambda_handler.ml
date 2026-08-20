(* Pure Lambda handler — OCaml port of [handle] in [infra/lambda/main.go].
   Authentication (A01), GET /products catalog route, body/base64 handling, and
   field validation all mirror Go's order and exact error strings. The API key
   and catalog are injected (no package-level mutable state), so the handler is
   fully testable in-process. *)

open Apicommand

(* The JSON body accepted by the handler. Every field defaults to its zero
   value, matching Go's [json.Unmarshal] with [omitempty] decode semantics —
   the tests omit fields freely (e.g. [{"ref":1,"stock":5}]). *)
type request = {
  ref : int [@default 0];
  description : string [@default ""];
  stock : int [@default 0];
  price : float [@default 0.0];
}
[@@deriving yojson]

(* The JSON response body: [{{"ok":..,"ref":..,"message":..}}], field order
   matching Go's [Response] struct so the bytes are identical. *)
type response_body = {
  ok : bool;
  ref : int;
  message : string;
}
[@@deriving yojson]

let max_description_bytes = 1024

let go_quote s =
  let buf = Buffer.create (String.length s + 2) in
  Buffer.add_char buf '"';
  String.iter
    (fun c ->
      let n = Char.code c in
      match c with
      | '\\' -> Buffer.add_string buf "\\\\"
      | '"' -> Buffer.add_string buf "\\\""
      | '\n' -> Buffer.add_string buf "\\n"
      | '\t' -> Buffer.add_string buf "\\t"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\b' -> Buffer.add_string buf "\\b"
      | '\012' -> Buffer.add_string buf "\\f"
      | '\007' -> Buffer.add_string buf "\\a"
      | '\011' -> Buffer.add_string buf "\\v"
      | _ when n < 0x20 || n = 0x7f ->
        Buffer.add_string buf (Printf.sprintf "\\x%02x" n)
      | _ -> Buffer.add_char buf c)
    s;
  Buffer.add_char buf '"';
  Buffer.contents buf

(* [message req available] is the availability line, byte-identical to Go's
   [fmt.Sprintf("ref=%d description=%q stock=%d price=%.2f -> available=%v",
   ...)]. *)
let message (req : request) available =
  Printf.sprintf "ref=%d description=%s stock=%d price=%.2f -> available=%b"
    req.ref (go_quote req.description) req.stock req.price available

(* [serve_catalog catalog] encodes the in-memory catalog as JSON; an empty list
   renders as [[]] (not [null]), matching Go's [serveCatalog] nil→[] guard. *)
let serve_catalog catalog =
  Event.ok (Wire.encode_products catalog)

(* [strip_slashes s] is Go's [strings.Trim(s, "/")] — drops every leading and
   trailing [/]. *)
let strip_slashes s =
  let len = String.length s in
  let lo = ref 0 and hi = ref len in
  while !lo < !hi && s.[!lo] = '/' do incr lo done;
  while !hi > !lo && s.[!hi - 1] = '/' do decr hi done;
  String.sub s !lo (!hi - !lo)

(* [decode_body event] base64-decodes the body when [isBase64Encoded], then
   parses the JSON into a [request]. Errors map to Go's exact 400 messages. *)
let decode_body event =
  let body =
    if not event.Event.is_base64_encoded then Ok event.Event.body
    else
      (match Base64.decode event.Event.body with
       | Ok d -> Ok d
       | Error _ -> Error "request body is not valid base64")
  in
  let body =
    match body with Error _ as e -> e | Ok b ->
      (try Ok (Yojson.Safe.from_string b)
       with Yojson.Json_error _ -> Error "invalid request body")
  in
  match body with
  | Error _ as e -> e
  | Ok json ->
    (match request_of_yojson json with
     | Ok _ as ok -> ok
     | Error _ -> Error "invalid request body")

(* [handle ~logger ~api_key ~catalog event] processes one invocation. Every
   branch returns an [Event.response]; no exceptions (Go returns nil error). *)
let handle ~logger ~api_key ~catalog event =
  (* A01: fail-closed on a missing/short configured key — deployment
     misconfiguration, not a caller error, so 500 to alert the operator. *)
  if String.length api_key < 32 then begin
    Log.error logger
      "LAMBDA_API_KEY missing or too short — refusing to serve with a weak key"
      [ "key_bytes", I (String.length api_key) ];
    Event.json_error 500 "internal server error"
  end
  else begin
    let provided = match Event.header event "x-api-key" with Some v -> v | None -> "" in
    if not (Constant_time.equal provided api_key) then begin
      Log.info logger "unauthorized request"
        [ "path", S event.Event.raw_path; "method", S event.Event.method_ ];
      Event.json_error 401 "unauthorized"
    end
    else begin
      (* GET /products: serve the reference catalog. *)
      if event.Event.method_ = "GET" && strip_slashes event.Event.raw_path = "products" then
        serve_catalog catalog
      else if String.trim event.Event.body = "" then
        Event.json_error 400 "missing request body"
      else
        (match decode_body event with
         | Error msg -> Event.json_error 400 msg
         | Ok req ->
           if String.length req.description > max_description_bytes then
             Event.json_error 400 "description exceeds 1KB"
           else if req.price < 0.0 then
             Event.json_error 400 "price must be >= 0"
           else if req.ref < 0 then
             Event.json_error 400 "ref must be >= 0"
           else begin
             let available = req.stock > 0 in
             let body =
               { ok = available; ref = req.ref; message = message req available }
               |> response_body_to_yojson |> Yojson.Safe.to_string
             in
             Event.ok body
           end)
    end
  end