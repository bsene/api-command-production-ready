(* OrdersManager — port of orders_manager.go. *)

open Product
open Lwt

module type HTTP_BACKEND = sig
  type response
  val request :
    method_:string -> url:string -> headers:(string * string) list ->
    (response, string) result Lwt.t
  val status : response -> int
  val body : response -> string
end

(* Default backend when none is injected. No caller that fetches relies on it
   — production injects Cohttp_backend, tests inject Fake_transport. Kept as a
   hard error so a misconfigured manager fails loudly instead of silently
   hitting the network. *)
module Stub_backend : HTTP_BACKEND = struct
  type response = unit
  let request ~method_:_ ~url:_ ~headers:_ = Lwt.return (Error "no http backend configured")
  let status _ = 0
  let body _ = ""
end

type search_result = { ref : int; description : string; available : bool; price : float }

type orders_manager = {
  base_url : string;
  api_key : string;
  mutable logger : Log.t;
  timeout_ms : float;
  http_client : (module HTTP_BACKEND);
}

let trim_trailing_slashes s =
  let n = String.length s in
  let rec i k = if k <= 0 then 0 else if s.[k - 1] = '/' then i (k - 1) else k in
  String.sub s 0 (i n)

let create ~base_url ?http_client ?(allow_insecure_http = false) ?(api_key = "")
    ?logger ?(timeout_ms = 10000.0) () =
  let trimmed = trim_trailing_slashes base_url in
  let logger = match logger with Some l -> l | None -> Log.create () in
  let http_client =
    match http_client with Some b -> b | None -> (module Stub_backend : HTTP_BACKEND)
  in
  match Ssrf.validate_base_url trimmed allow_insecure_http with
  | Error msg -> Error msg
  | Ok () ->
      Ok { base_url = trimmed; api_key;
           logger; timeout_ms; http_client }

let base_url m = m.base_url
let set_logger m l = m.logger <- l

(* --- fetch --------------------------------------------------------------- *)

let fetch_products m =
  let url = m.base_url ^ "/products" in
  let headers = if m.api_key = "" then [] else [ "x-api-key", m.api_key ] in
  let module B = (val m.http_client) in
  let timed =
    Lwt.pick
      [ B.request ~method_:"GET" ~url ~headers
      ; Lwt_unix.sleep (m.timeout_ms /. 1000.0) >>= fun () ->
        Lwt.return (Error "context deadline exceeded") ]
  in
  timed >>= function
  | Error msg ->
      Log.error m.logger "requesting products failed" [ "url", Log.S url ];
      Lwt.return (Error ("requesting products: " ^ msg))
  | Ok resp ->
      let status = B.status resp in
      if status <> 200 then begin
        Log.warn m.logger "products API returned non-OK status"
          [ "url", Log.S url; "status", Log.I status ];
        Lwt.return
          (Error (Printf.sprintf "products API returned status %d" status))
      end else
        match Wire.decode_products (B.body resp) with
        | Error msg ->
            Log.error m.logger "decoding products response failed"
              [ "url", Log.S url; "status", Log.I status ];
            Lwt.return (Error ("decoding products: " ^ msg))
        | Ok ps ->
            Log.info m.logger "products request completed"
              [ "url", Log.S url; "status", Log.I status;
                "product_count", Log.I (List.length ps) ];
            Lwt.return (Ok ps)

(* --- helpers (ports of sortedDescriptions / filterAvailable / ... ) ------- *)

let contains_sub s sub =
  let n = String.length s and m = String.length sub in
  let rec go i =
    if i + m > n then false
    else if String.sub s i m = sub then true else go (i + 1)
  in
  if m = 0 then true else go 0

let product_available (p : product) : bool = p.stock > 0

let sorted_descriptions (ps : product list) : string list =
  ps |> List.map (fun (p : product) -> p.description) |> List.sort String.compare

let find_product (m : orders_manager) (ref : int) : (product, string) result Lwt.t =
  fetch_products m >>= function
  | Error e -> Lwt.return (Error e)
  | Ok ps ->
      let rec go : product list -> (product, string) result Lwt.t = function
        | [] -> Lwt.return (Error (Printf.sprintf "product %d not found" ref))
        | p :: rest -> if p.ref = ref then Lwt.return (Ok p) else go rest
      in
      go ps

(* --- public query methods ------------------------------------------------ *)

let all_descriptions m =
  fetch_products m >>= function
  | Error e -> Lwt.return (Error e)
  | Ok ps -> Lwt.return (Ok (sorted_descriptions ps))

let available_descriptions m =
  fetch_products m >>= function
  | Error e -> Lwt.return (Error e)
  | Ok ps ->
      let av = List.filter product_available ps in
      Lwt.return (Ok (sorted_descriptions av))

let is_available m ref =
  find_product m ref >>= function
  | Error e -> Lwt.return (Error e)
  | Ok p -> Lwt.return (Ok (product_available p))

let search m keyword =
  fetch_products m >>= function
  | Error e -> Lwt.return (Error e)
  | Ok ps ->
      let needle = String.lowercase_ascii keyword in
      let matches =
        List.filter
          (fun (p : product) ->
            String.lowercase_ascii p.description
            |> fun d -> contains_sub d needle)
          ps
      in
      let results =
        List.map
          (fun (p : product) ->
            { ref = p.ref; description = p.description;
              available = product_available p; price = p.price })
          matches
      in
      Lwt.return (Ok results)

let validate_cart m cart =
  fetch_products m >>= function
  | Error e -> Lwt.return (Error (`Fetch e))
  | Ok ps ->
      let by_ref = List.map (fun (p : product) -> p.ref, p) ps in
      let issues = ref [] in
      List.iter
        (fun item ->
          if Product.validate_cart_item item = Error `Invalid_quantity then
            issues :=
              { ref = item.ref; requested = item.quantity; available = 0;
                reason = InvalidQuantity }
              :: !issues
          else
            match List.assoc_opt item.ref by_ref with
            | None ->
                issues :=
                  { ref = item.ref; requested = item.quantity; available = 0;
                    reason = NotAvailable }
                  :: !issues
            | Some p ->
                if p.stock < item.quantity then
                  issues :=
                    { ref = item.ref; requested = item.quantity;
                      available = p.stock; reason = InsufficientStock }
                    :: !issues)
        cart;
      let details = List.rev !issues in
      if details <> [] then begin
        Log.warn m.logger "cart validation failed"
          [ "item_count", Log.I (List.length cart);
            "invalid_count", Log.I (List.length details) ];
        Lwt.return (Error (`Invalid_cart (Product.invalid_cart_error details)))
      end else
        let total =
          List.fold_left
            (fun acc (item : Product.cart_item) ->
              match List.assoc_opt item.ref by_ref with
              | Some p -> acc +. p.price *. float_of_int item.quantity
              | None -> acc)
            0.0 cart
        in
        Lwt.return (Ok { Product.valid = true; total_price = total })