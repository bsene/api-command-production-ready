package apicommand

import "fmt"

// Product is a sports product returned by the products API.
type Product struct {
	Ref         int     `json:"ref"`
	Description string  `json:"description"`
	Stock       int     `json:"stock"`
	Price       float64 `json:"prix"`
}

// IsAvailable reports whether the product is in stock.
func (p Product) IsAvailable() bool {
	return p.Stock > 0
}

// Quantity is a positive count of units in a cart line. A valid Quantity is
// always > 0; zero or negative values are rejected by NewQuantity so that an
// invalid quantity cannot reduce or zero the cart total (A04 insecure design).
//
// Quantity is a named int type so that the "must be positive" invariant lives
// with the type rather than being scattered across consumer functions. The
// only supported way to build a Quantity from arbitrary input is NewQuantity,
// which validates the sign. Literal construction (e.g. Quantity(2)) remains
// possible for trusted constants, but any externally-sourced value must go
// through NewQuantity.
type Quantity int

// NewQuantity builds a Quantity from an int, returning an error if n is zero
// or negative. Use this for any externally-sourced value so the invalid state
// is unrepresentable (A04 insecure design prevention).
func NewQuantity(n int) (Quantity, error) {
	if n <= 0 {
		return 0, fmt.Errorf("invalid quantity %d: must be positive", n)
	}
	return Quantity(n), nil
}

// Int returns the underlying int value of the Quantity.
func (q Quantity) Int() int { return int(q) }

// ErrInvalidQuantity is returned by CartItem.Validate when its quantity is
// zero or negative.
var ErrInvalidQuantity = fmt.Errorf("cart item quantity must be positive")

// CartItem is one line of a customer cart: a product reference and a quantity.
type CartItem struct {
	Ref      int
	Quantity Quantity
}

// Validate reports whether the cart item satisfies its invariants. It rejects
// zero or negative quantities so a negative quantity can never reduce or zero
// the cart total (A04 insecure design). The invariant lives with the type so
// any future cart-related validation can delegate to it.
func (ci CartItem) Validate() error {
	if ci.Quantity <= 0 {
		return ErrInvalidQuantity
	}
	return nil
}

// CartValidation is the result of checking a cart against current stock.
type CartValidation struct {
	Valid      bool
	TotalPrice float64
}

// CartItemIssue records one problem found in a cart item.
type CartItemIssue struct {
	Ref       int
	Requested int
	Available int
	Reason    CartItemIssueReason
}

// CartItemIssueReason classifies why a cart item is invalid.
type CartItemIssueReason int

const (
	// CartItemNotAvailable means the product doesn't exist or has zero stock.
	CartItemNotAvailable CartItemIssueReason = iota
	// CartItemInsufficientStock means the product exists but not enough units.
	CartItemInsufficientStock
	// CartItemInvalidQuantity means the requested quantity is zero or negative,
	// which would reduce or zero the cart total (A04 insecure design).
	CartItemInvalidQuantity
)

// InvalidCartError is returned by ValidateCart when one or more items cannot be fulfilled.
//
// The HTTP status mapping is documented in StatusCode so that an HTTP layer
// (cmd/server, the client call sites) can turn it into a real response.
//
// Details lists every offending line so the caller can report per-item feedback.
type InvalidCartError struct {
	// Code is the HTTP status the caller should use (422).
	Code int
	// Details is the list of cart lines that failed validation.
	Details []CartItemIssue
}

func (e *InvalidCartError) Error() string {
	return fmt.Sprintf("cart invalid: %d item(s) cannot be fulfilled", len(e.Details))
}
