(** JSON wire codecs — isolates the French "prix" key from the domain
    [Product.product] (which uses the English [price] field). *)

(** Wire shape of a catalog product; [price] serializes to the JSON key
    "prix", matching the Go [Product] struct tag and the catalog fixture. *)
type product_wire = {
  ref : int;
  description : string;
  stock : int;
  price : float;
}
[@@deriving yojson]

val to_product : product_wire -> Product.product
val of_product : Product.product -> product_wire

(** [encode_products ps] serializes a product list to a JSON string, preserving
    list (positional) order — load-bearing for the Hurl smoke tests. *)
val encode_products : Product.product list -> string

(** [decode_products s] parses a JSON array of catalog products. *)
val decode_products : string -> (Product.product list, string) result