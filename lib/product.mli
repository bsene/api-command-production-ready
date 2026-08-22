(** Domain types for the api-command kata — OCaml port of [product.go]. *)

(** A sports product returned by the products API. The [price] field is the
    domain (English) name; the wire layer ([Wire]) maps it to the French
    JSON key "prix", matching the Go struct tag. *)
type product = {
  ref : int;
  description : string;
  stock : int;
  price : float;
}

(** [is_available p] reports whether [p] is in stock (stock > 0). *)
val is_available : product -> bool

(** A positive count of units in a cart line.

    Mirrors Go's [type Quantity int]: a named int whose "must be positive"
    invariant is enforced by [create_quantity] but whose transparent
    representation still allows literal construction (as the Go tests do with
    [CartItem{Quantity: -3}]). Keeping the type transparent preserves faithful
    white-box test coverage; the smart constructor remains the recommended way
    to build a [quantity] from external input. *)
type quantity = int

(** [create_quantity n] builds a [quantity] from [n], returning
    [Error (`Invalid_quantity n)] when [n <= 0] so an invalid quantity cannot
    reduce or zero a cart total (A04 insecure design). *)
val create_quantity : int -> (quantity, [> `Invalid_quantity of int]) result

val quantity_to_int : quantity -> int

(** One cart line: a product reference and a quantity. *)
type cart_item = {
  ref : int;
  quantity : quantity;
}

(** [validate_cart_item item] rejects zero or negative quantities (A04). *)
val validate_cart_item : cart_item -> (unit, [> `Invalid_quantity]) result

(** Result of checking a cart against current stock. *)
type cart_validation = {
  valid : bool;
  total_price : float;
}

(** Classification of why a cart item is invalid. *)
type cart_item_issue_reason =
  | NotAvailable
  | InsufficientStock
  | InvalidQuantity

(** One problem found in a cart item. *)
type cart_item_issue = {
  ref : int;
  requested : int;
  available : int;
  reason : cart_item_issue_reason;
}

(** Error returned when one or more cart items cannot be fulfilled.
    [code] is the HTTP status (422); [details] lists every offending line. *)
type invalid_cart_error = {
  code : int;
  details : cart_item_issue list;
}

(** [invalid_cart_error details] builds the error with code 422. *)
val invalid_cart_error : cart_item_issue list -> invalid_cart_error

(** [invalid_cart_error_message e] renders the error message, matching Go's
    [fmt.Sprintf("cart invalid: %d item(s) cannot be fulfilled", ...)]. *)
val invalid_cart_error_message : invalid_cart_error -> string