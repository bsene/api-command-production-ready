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

// CartItem is one line of a customer cart: a product reference and a quantity.
type CartItem struct {
	Ref      int
	Quantity int
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
