(* Dream HTTP app — server, middleware chain, and hardening. Middleware order
   is outermost-first, matching the [chain] order:
   request_logger → recover → enforce_max_header_bytes → security_headers →
   api_key_auth → router. [Dream.handler @@ a @@ b @@ router] composes so [a]
   runs outermost. *)

open Apicommand
open Lwt

(* Hardening constant — Go's [http.Server{MaxHeaderBytes: 1 << 20}]. Dream does
   not expose a per-server header-size cap, so this is the configured value
   asserted by the white-box test (A05). *)
let max_header_bytes = 1 lsl 20

(* GET /products — encodes the in-memory catalog as JSON (positional order
   preserved by [Wire.encode_products], load-bearing for the Hurl suite). *)
let products_handler catalog _request =
  Dream.json (Wire.encode_products catalog)

(* A01: constant-time api-key gate. [subtle.ConstantTimeCompare] →
   [Constant_time.equal]; 401 with [WWW-Authenticate: ApiKey] on mismatch. *)
let api_key_auth key next request =
  match Dream.header request "x-api-key" with
  | Some provided when Constant_time.equal provided key -> next request
  | _ ->
    Dream.respond ~status:`Unauthorized
      ~headers:[ "WWW-Authenticate", "ApiKey"
               ; "Content-Type", "text/plain; charset=utf-8" ]
      "unauthorized\n"

(* A02/A05: baseline defensive headers. Set on the response after the inner
   handler produces it, so they apply to every status (401, 404, 200). HSTS only
   over TLS, matching Go's [r.TLS != nil] guard. *)
let security_headers next request =
  next request >>= fun resp ->
  Dream.set_header resp "X-Content-Type-Options" "nosniff";
  Dream.set_header resp "X-Frame-Options" "DENY";
  Dream.set_header resp "Cache-Control" "no-store";
  Dream.set_header resp "Content-Security-Policy" "default-src 'none'";
  if Dream.tls request then
    Dream.set_header resp "Strict-Transport-Security"
      "max-age=31536000; includeSubDomains";
  return resp

(* A05: enforce MaxHeaderBytes in-process. Dream has no built-in per-server
   header-size cap, so this middleware measures the parsed header set plus the
   HTTP/1.1 request line and rejects with 431 before the handler or downstream
   middleware processes the headers any further. The count mirrors Go's
   [http.Server.MaxHeaderBytes]: request line + each [Name: Value\r\n] + the
   terminal [\r\n]. *)
let enforce_max_header_bytes next request =
  let request_line_size =
    String.length (Dream.method_to_string (Dream.method_ request))
    + String.length (Dream.target request)
    + 12
  in
  let header_size =
    List.fold_left
      (fun acc (name, value) ->
         acc + String.length name + String.length value + 4)
      0 (Dream.all_headers request)
  in
  if request_line_size + header_size + 2 > max_header_bytes then
    Dream.respond ~status:`Request_Header_Fields_Too_Large
      ~headers:[ "Content-Type", "text/plain; charset=utf-8" ]
      "request header fields too large\n"
  else
    next request

(* A05: recover from exceptions in any downstream handler/middleware and return
   a clean 500 instead of crashing. Uses [Lwt.catch] (catches exceptions and
   rejections only, NOT 4xx/5xx responses — unlike [Dream.catch], which would
   intercept the 401 from [api_key_auth]). *)
let recover logger next request =
  Lwt.catch
    (fun () -> next request)
    (fun exn ->
      Log.error logger "panic recovered"
        [ "method", S (Dream.method_to_string (Dream.method_ request))
        ; "path", S (Dream.target request)
        ; "remote", S (Dream.client request)
        ; "panic", S (Printexc.to_string exn) ];
      Dream.respond ~status:`Internal_Server_Error
        ~headers:[ "Content-Type", "text/plain; charset=utf-8" ]
        "internal server error\n")

(* A09: access log — method, path, status, remote, elapsed_ms. Status is read
   from the response after the inner handler runs, mirroring Go's
   [statusRecorder]. *)
let request_logger logger next request =
  let start = Unix.gettimeofday () in
  next request >>= fun resp ->
  let elapsed_ms =
    int_of_float ((Unix.gettimeofday () -. start) *. 1000.)
  in
  Log.info logger "request"
    [ "method", S (Dream.method_to_string (Dream.method_ request))
    ; "path", S (Dream.target request)
    ; "status", I (Dream.status_to_int (Dream.status resp))
    ; "remote", S (Dream.client request)
    ; "elapsed_ms", I elapsed_ms ];
  return resp

(* Middleware chain, outermost-first; recovery sits outside the size gate so
   its exceptions are still logged and converted to 500. *)
let app ~catalog ~api_key ~logger =
  let router =
    Dream.router [ Dream.get "/products" (products_handler catalog) ]
  in
  request_logger logger
  @@ recover logger
  @@ enforce_max_header_bytes
  @@ security_headers
  @@ api_key_auth api_key
  @@ router