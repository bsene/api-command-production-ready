(* Domain types for the api-command kata — OCaml port of product.go. *)

type product = {
  ref : int;
  description : string;
  stock : int;
  price : float;
}

let is_available p = p.stock > 0

type quantity = int

let create_quantity n =
  if n <= 0 then Error (`Invalid_quantity n) else Ok n

let quantity_to_int q = q

type cart_item = {
  ref : int;
  quantity : quantity;
}

let validate_cart_item ci =
  if ci.quantity <= 0 then Error `Invalid_quantity else Ok ()

type cart_validation = {
  valid : bool;
  total_price : float;
}

type cart_item_issue_reason =
  | NotAvailable
  | InsufficientStock
  | InvalidQuantity

type cart_item_issue = {
  ref : int;
  requested : int;
  available : int;
  reason : cart_item_issue_reason;
}

type invalid_cart_error = {
  code : int;
  details : cart_item_issue list;
}

let invalid_cart_error details = { code = 422; details }

let invalid_cart_error_message e =
  Printf.sprintf "cart invalid: %d item(s) cannot be fulfilled"
    (List.length e.details)