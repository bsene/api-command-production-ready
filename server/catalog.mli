open Apicommand

(** Catalog loading — reads the on-disk products fixture and decodes it via
    [Wire], preserving positional order (load-bearing for the Hurl smoke
    tests, which assert idx0..idx15). *)

(** [load_catalog ~path] reads [path] and decodes the JSON array of products.
    Returns [Error msg] on read failure ([Sys_error]) or decode failure.
    Order is preserved end-to-end: the JSON array order becomes the list
    order, which [Wire.encode_products] re-emits in the same order. *)
val load_catalog : path:string -> (Product.product list, string) result