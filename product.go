package apicommand

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
