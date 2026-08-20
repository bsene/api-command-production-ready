(* API Gateway v2 (HTTP API) payload-format-2.0 event codec — the shape a Lambda
   Function URL delivers to the handler. The raw HTTP body lives in [body], not
   at the top level. Header keys arrive lowercased by APIGW, but [header] looks
   them up case-insensitively anyway (defense-in-depth, matching Go's
   [event.Headers["x-api-key"]] which relies on the lowercasing). *)

type event = {
  headers : (string * string) list;
  body : string;
  is_base64_encoded : bool;
  raw_path : string;
  method_ : string;
}

type response = {
  status_code : int;
  headers : (string * string) list;
  body : string;
}

(* Case-insensitive header lookup, like Go's map access on lowercased keys. *)
let header (ev : event) name =
  let n = String.lowercase_ascii name in
  List.find_opt (fun (k, _) -> String.lowercase_ascii k = n) ev.headers
  |> Option.map snd

let get_string assoc k =
  match List.assoc_opt k assoc with Some (`String s) -> s | _ -> ""

let get_bool assoc k =
  match List.assoc_opt k assoc with Some (`Bool b) -> b | _ -> false

(* Hand-rolled decode: the APIGW v2 event is a fixed nested shape, so a ppx
   record codec would add machinery without value. Unknown/missing fields fall
   back to zero values, mirroring Go's [json.Unmarshal] into a struct. *)
let of_json s =
  try
    let j = Yojson.Safe.from_string s in
    let assoc = match j with `Assoc a -> a | _ -> [] in
    let headers =
      match List.assoc_opt "headers" assoc with
      | Some (`Assoc hs) ->
        List.map (fun (k, v) -> (k, match v with `String s -> s | _ -> "")) hs
      | _ -> []
    in
    let method_ =
      match List.assoc_opt "requestContext" assoc with
      | Some (`Assoc rc) ->
        (match List.assoc_opt "http" rc with
         | Some (`Assoc h) -> get_string h "method"
         | _ -> "")
      | _ -> ""
    in
    Ok
      { headers;
        body = get_string assoc "body";
        is_base64_encoded = get_bool assoc "isBase64Encoded";
        raw_path = get_string assoc "rawPath";
        method_ }
  with Yojson.Json_error e -> Error e

(* [json_error status msg] is the JSON error body [{{"error": msg}}] used for
   every non-200 path, matching Go's [jsonError]. *)
let json_error status msg : response =
  { status_code = status;
    headers = [ "Content-Type", "application/json" ];
    body = Yojson.Safe.to_string (`Assoc [ "error", `String msg ]) }

(* [ok body] is a 200 with an [application/json] body. *)
let ok ?(headers = [ "Content-Type", "application/json" ]) body : response =
  { status_code = 200; headers; body }