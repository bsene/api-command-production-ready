# Dantotsu Analysis: Negative cart quantity reduces or zeroes the cart total

## Problem Statement

`CartItem.Quantity` accepted any integer, including zero and negative values.
`ValidateCart` multiplied `product.Price * float64(item.Quantity)` without
checking the sign, so a negative quantity reduced the cart total — potentially
to zero or negative — bypassing the business-logic price check.

---

## Metadata

| Field                   | Value                                                      |
| ----------------------- | ---------------------------------------------------------- |
| 🟢 **ID**               | `OWASP-A04-NEGATIVE-QTY`                                   |
| 🟢 **Analysis Date**    | `2026/08/19`                                               |
| 🟢 **Project**          | `api-command-kata`                                         |
| 🟢 **Detection Stage**  | `B — Security audit (OWASP Top 10 review)`                 |
| 🟢 **Startup**          | `bsene`                                                    |
| 🟢 **Status**           | `Fixed`                                                    |
| 🔵 **Weak point**       | `lib/orders_manager.ml — validate_cart`                   |
| 🟢 **Owner**            | `birrame.sene`                                             |
| 🟢 **napta_project_id** | `api-command`                                              |
| **Standard**            | 🎓 Dantotsu                                                |

---

## User Impact

A caller can submit a cart like `[{Ref: 1, Quantity: -2}]` and
`ValidateCart` returns `{Valid: true, TotalPrice: -2800}` — a "valid" cart
with a negative total. In a real ordering system this could be exploited to:
- Zero out a cart total (add a negative-quantity item offsetting positive
  items).
- Submit an order with a reduced or negative price.
- Bypass minimum-order-value checks.

---

## Causal Chain

1. `CartItem` is a plain struct with `Ref int` and `Quantity int` — no
   validation method, no constructor, no invariant.
2. `ValidateCart` iterates cart items and checks only two conditions:
   product existence and stock sufficiency. It never checks that
   `Quantity > 0`.
3. The total is computed as `product.Price * float64(item.Quantity)`. With
   `Quantity = -2`, this yields a negative contribution.
4. Because no validation error is raised, the cart is marked `Valid: true`
   with the corrupted total.

---

## Root Cause of Occurrence

The domain model treated `Quantity` as an unvalidated primitive integer
rather than a constrained value object.

### The Misconception

"Quantity is just an `int` — the caller will always pass a positive number.
The only business rule that matters is 'is there enough stock?', which is
checked by `product.Stock < item.Quantity`."

### What Actually Happened

1. `int` in Go accepts negatives, zero, and `MinInt`. There is no language-level
   constraint for "positive integer."
2. The stock check `product.Stock < item.Quantity` is a range comparison, not
   a sign check. With `Quantity = -2` and `Stock = 10`, the condition
   `10 < -2` is false, so the item passes as if it were a valid request for
   2 units.
3. The total computation runs unconditionally for all items that passed the
   stock check, multiplying by the negative quantity.

### Contributing Factor

`CartItem` has no `Validate()` method and no constructor — it can be
constructed with any field values. The validation logic is centralized in
`ValidateCart`, which makes it easy to forget a precondition when adding
new checks.

---

## Detection Failure Causes

### 1. Code Complexity (Local Validation Failure)

The `ValidateCart` function is ~30 lines with two nested loops and an error
accumulator. The quantity sign check is absent in a function that already
looks "complete" — it has product-existence checks and stock checks, so a
reviewer assumes all invariants are covered.

### 2. Process Gap

No security review checklist item for "business-logic input validation" was
applied. The OWASP audit caught it under A04 (Insecure Design) but it was
filed alongside the SSRF finding, diluting focus.

### 3. Missing Tests

The test suite had `TestValidateCart` with 6 sub-tests covering valid carts,
empty carts, out-of-stock, quantity-exceeds-stock, unknown product, and mixed
valid/invalid. None tested negative or zero quantities. A single
`{Ref: 1, Quantity: -1}` test case would have caught this.

### 4. Code Review

The reviewer saw `product.Stock < item.Quantity` and assumed it was a
sufficient guard. The comparison looks correct for positive quantities but
silently passes negative ones.

---

## Countermeasure

### Changes Made

1. Added `Cart_item_invalid_quantity` to the `cart_item_issue_reason` enum in
   `lib/product.ml`.

2. In `ValidateCart`, the first check per item is now
   `if item.Quantity <= 0` — before product existence or stock checks. This
   ensures a negative or zero quantity is rejected immediately and the item
   is added to `errs.Details` with `Reason: CartItemInvalidQuantity`.

3. Because the quantity check runs before the stock check, a negative
   quantity can never reach the total computation. The `if len(errs.Details)
   > 0` guard returns an `InvalidCartError` before the total is calculated.

4. Added 4 test cases:
   - `TestValidateCart_rejectsNegativeQuantity` — verifies error and reason.
   - `TestValidateCart_rejectsZeroQuantity` — verifies zero is also rejected.
   - `TestValidateCart_rejectsNegativeQuantityDoesNotReduceTotal` — verifies
     a mixed cart with a negative qty is rejected (no valid result returned).
   - `TestValidateCart_negativeAndValidMixed` — verifies multiple issues are
     reported together (invalid qty + out of stock).

### Result

- `ValidateCart(ctx, [{Ref: 1, Quantity: -2}])` → returns
  `InvalidCartError` with `Details: [{Ref:1, Requested:-2, Reason:CartItemInvalidQuantity}]`,
  never a valid result.
- `ValidateCart(ctx, [{Ref: 1, Quantity: 2}, {Ref: 2, Quantity: -5}])` →
  rejected (the negative item fails before the total is computed).
- Positive quantities continue to work unchanged.

---

## Eradication

### Similar Instances

`CartItem` is the only domain type with a numeric quantity field. No other
struct in the codebase has a similar "primitive int that should be positive"
pattern.

### Prevention Strategy

- Consider adding a `CartItem.Validate() error` method so the invariant lives
  with the type, not scattered across consumer functions.
- Add a lint/review checklist item: "Any `int` field representing a count or
  quantity must be validated for `> 0` at the point of use."
- The `quantity` type is an `int` alias by design. The guard is
  **validate-at-use** (`validate_cart_item` / the `<= 0` check at the top of
  `validate_cart`); it does *not* make invalid state unrepresentable at
  construction. Do not tighten the type — keep the alias and enforce the
  check at the point of use.

### Weak Point History

First occurrence. The weak point is `ValidateCart` as the single business-rule
gate. Any future cart-related validation must check quantity sign before
proceeding to stock or price computations.
