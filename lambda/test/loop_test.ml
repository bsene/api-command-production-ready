(* L3c, T1: exercises the custom-runtime loop against a stub Runtime API.
   A Dream server impersonates the Lambda Runtime API: GET [/next] returns one
   fixed invocation, POST [/response] captures the encoded response. We run
   [Runtime.serve_one] once and assert the captured envelope carries the
   handler's availability message. The test is sync at the Alcotest layer and
   drives the async work through a single [Lwt_main.run]. *)

open Lambda_lib

let key = "0123456789abcdef0123456789abcdef"
let logger = Apicommand.Log.create ()
let port = 18923

let event_json =
  {|{"headers":{"x-api-key":"|} ^ key ^
  {|"},"body":"{\"ref\":1,\"description\":\"vélo\",\"stock\":10,\"price\":1400}","isBase64Encoded":false,"rawPath":"/avail","requestContext":{"http":{"method":"POST"}}}|}

(* [stub captured] is the Runtime API impersonator. *)
let stub captured req =
  match Dream.method_ req, Dream.target req with
  | `GET, "/runtime/invocation/next" ->
    Lwt.return
      (Dream.response
         ~headers:[ "Lambda-Runtime-Aws-Request-Id", "test-1" ]
         event_json)
  | `POST, target
    when String.starts_with ~prefix:"/runtime/invocation/" target ->
    let%lwt body = Dream.body req in
    captured := body;
    Dream.empty `OK
  | _ -> Dream.empty `Not_Found

let message_inside envelope =
  match Yojson.Safe.from_string envelope with
  | `Assoc a ->
    (match List.assoc_opt "body" a with
     | Some (`String inner) ->
       (match Yojson.Safe.from_string inner with
        | `Assoc ia ->
          (match List.assoc_opt "message" ia with
           | Some (`String s) -> s
           | _ -> "")
        | _ -> "")
     | _ -> "")
  | _ -> ""

let test_serve_one_roundtrip () =
  let captured = ref "" in
  let body =
    Lwt_main.run
      (let stop, fulfill = Lwt.wait () in
       let server = Dream.serve ~interface:"127.0.0.1" ~port ~stop (stub captured) in
       let%lwt () = Lwt_unix.sleep 0.2 in
       let%lwt () =
         Runtime.serve_one ~api:"127.0.0.1:18923" ~api_key:key ~catalog:[] ~logger
       in
       let%lwt () = Lwt_unix.sleep 0.05 in
       Lwt.wakeup fulfill ();
       let%lwt () = server in
       Lwt.return !captured)
  in
  Alcotest.(check bool) "response POSTed" true (String.length body > 0);
  let msg = message_inside body in
  Alcotest.(check string) "message contains available=true"
    "ref=1 description=\"vélo\" stock=10 price=1400.00 -> available=true" msg;
  Alcotest.(check string) "envelope wraps APIGW response"
    "200"
    (match Yojson.Safe.from_string body with
     | `Assoc a -> (match List.assoc_opt "statusCode" a with Some (`Int n) -> string_of_int n | _ -> "?")
     | _ -> "?")

let () =
  Alcotest.run "lambda-runtime"
    [ ("loop",
       [ Alcotest.test_case "serve_one roundtrip" `Quick test_serve_one_roundtrip
       ]) ]