(** API Gateway v2 (HTTP API) payload-format-2.0 event codec — the request shape
    a Lambda Function URL delivers to the handler. OCaml port of the
    [events.APIGatewayV2HTTPRequest] fields used by [infra/lambda/main.go]. *)

(** A single Function URL invocation. [headers] keys are stored as-delivered
    (APIGW lowercases them); look them up with [header]. *)
type event = {
  headers : (string * string) list;
  body : string;
  is_base64_encoded : bool;
  raw_path : string;
  method_ : string;
}

(** The HTTP response returned to the Runtime API, mirroring
    [events.APIGatewayV2HTTPResponse]. *)
type response = {
  status_code : int;
  headers : (string * string) list;
  body : string;
}

(** [header ev name] looks up header [name] case-insensitively. *)
val header : event -> string -> string option

(** [of_json s] decodes an APIGW v2 event JSON. Missing fields default to the
    zero value, matching Go's [json.Unmarshal]. *)
val of_json : string -> (event, string) result

(** [json_error status msg] builds a JSON [{{"error": msg}}] response. *)
val json_error : int -> string -> response

(** [ok ?headers body] builds a 200 response. *)
val ok : ?headers:(string * string) list -> string -> response