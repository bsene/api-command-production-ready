(* JSON wire codecs for catalog products. The [price] field maps to the
   French JSON key "prix" via [@key "prix"], mirroring the Go struct tag.
   ppx_deriving_yojson 3.8 generates [to_yojson]/[of_yojson] over
   Yojson.Safe and returns an [error_or] (= (t, string) result). *)

type product_wire = {
  ref : int [@key "ref"];
  description : string [@key "description"];
  stock : int [@key "stock"];
  price : float [@key "prix"];
}
[@@deriving yojson]

let to_product (w : product_wire) : Product.product =
  { Product.ref = w.ref; Product.description = w.description;
    Product.stock = w.stock; Product.price = w.price }

let of_product (p : Product.product) : product_wire =
  { ref = p.Product.ref; description = p.Product.description;
    stock = p.Product.stock; price = p.Product.price }

(* Render integral floats as JSON integers (e.g. [1400] not [1400.0]) so the
   catalog bytes match Go's [encoding/json] output exactly — load-bearing for
   the Hurl [jsonpath "$[0].prix" == 1400] assertions and the byte-equal
   Lambda-message check (risk #4). Non-integral prices keep their decimal
   form ([1.5], [34.9]). *)
let rec compact_floats = function
  | `Float f when Float.is_integer f -> `Int (int_of_float f)
  | `Assoc kvs -> `Assoc (List.map (fun (k, v) -> (k, compact_floats v)) kvs)
  | `List xs -> `List (List.map compact_floats xs)
  | other -> other

let encode_products ps =
  ps |> List.map of_product |> List.map product_wire_to_yojson
  |> (fun xs -> `List xs)
  |> compact_floats
  |> Yojson.Safe.to_string

let decode_products s =
  try
    let json = Yojson.Safe.from_string s in
    match json with
    | `List xs ->
        let rec loop acc = function
          | [] -> Ok (List.rev acc)
          | x :: rest ->
              (match product_wire_of_yojson x with
               | Ok w -> loop (to_product w :: acc) rest
               | Error msg -> Error msg)
        in
        loop [] xs
    | _ -> Ok []
  with Yojson.Json_error msg -> Error msg