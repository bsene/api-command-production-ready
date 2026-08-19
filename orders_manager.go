package apicommand

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"
)

// OrdersManager prepares sports-product orders by consuming the products API.
type OrdersManager struct {
	baseURL string
	client  *http.Client
}

// Option configures an OrdersManager.
type Option func(*OrdersManager)

// WithHTTPClient overrides the default HTTP client.
func WithHTTPClient(client *http.Client) Option {
	return func(m *OrdersManager) { m.client = client }
}

// NewOrdersManager creates an OrdersManager targeting the given API base URL
// (e.g. "https://products.com").
func NewOrdersManager(baseURL string, opts ...Option) *OrdersManager {
	m := &OrdersManager{
		baseURL: strings.TrimRight(baseURL, "/"),
		client:  &http.Client{Timeout: 10 * time.Second},
	}
	for _, opt := range opts {
		opt(m)
	}
	return m
}

// AllDescriptions returns the description of every product, sorted alphabetically.
func (m *OrdersManager) AllDescriptions(ctx context.Context) ([]string, error) {
	products, err := m.fetchProducts(ctx)
	if err != nil {
		return nil, err
	}
	return sortedDescriptions(products), nil
}

// AvailableDescriptions returns the description of every product with stock > 0,
// sorted alphabetically.
func (m *OrdersManager) AvailableDescriptions(ctx context.Context) ([]string, error) {
	products, err := m.fetchProducts(ctx)
	if err != nil {
		return nil, err
	}
	available := filterAvailable(products)
	return sortedDescriptions(available), nil
}

// IsAvailable reports whether the product with the given reference has stock > 0.
func (m *OrdersManager) IsAvailable(ctx context.Context, ref int) (bool, error) {
	product, err := m.findProduct(ctx, ref)
	if err != nil {
		return false, err
	}
	return product.IsAvailable(), nil
}

// SearchResult is a product matching a keyword search, with its availability and price.
type SearchResult struct {
	Ref         int
	Description string
	Available   bool
	Price       float64
}

// Search returns the products whose description contains the keyword (case-insensitive).
func (m *OrdersManager) Search(ctx context.Context, keyword string) ([]SearchResult, error) {
	products, err := m.fetchProducts(ctx)
	if err != nil {
		return nil, err
	}
	needle := strings.ToLower(keyword)
	matches := filterByKeyword(products, needle)
	return toSearchResults(matches), nil
}

// ValidateCart reports whether every cart item is available in the requested quantity
// and computes the total price.
func (m *OrdersManager) ValidateCart(ctx context.Context, cart []CartItem) (CartValidation, error) {
	products, err := m.fetchProducts(ctx)
	if err != nil {
		return CartValidation{}, err
	}
	byRef := indexByRef(products)

	valid := true
	var totalPrice float64
	for _, item := range cart {
		product, ok := byRef[item.Ref]
		if !ok || product.Stock < item.Quantity {
			valid = false
			continue
		}
		totalPrice += product.Price * float64(item.Quantity)
	}
	return CartValidation{Valid: valid, TotalPrice: totalPrice}, nil
}

func (m *OrdersManager) fetchProducts(ctx context.Context) ([]Product, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, m.baseURL+"/products", nil)
	if err != nil {
		return nil, fmt.Errorf("building products request: %w", err)
	}

	resp, err := m.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("requesting products: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("products API returned status %d", resp.StatusCode)
	}

	var products []Product
	if err := json.NewDecoder(resp.Body).Decode(&products); err != nil {
		return nil, fmt.Errorf("decoding products: %w", err)
	}
	return products, nil
}

func (m *OrdersManager) findProduct(ctx context.Context, ref int) (Product, error) {
	products, err := m.fetchProducts(ctx)
	if err != nil {
		return Product{}, err
	}
	for _, product := range products {
		if product.Ref == ref {
			return product, nil
		}
	}
	return Product{}, fmt.Errorf("product %d not found", ref)
}

func sortedDescriptions(products []Product) []string {
	descriptions := make([]string, 0, len(products))
	for _, product := range products {
		descriptions = append(descriptions, product.Description)
	}
	sort.Strings(descriptions)
	return descriptions
}

func filterAvailable(products []Product) []Product {
	available := make([]Product, 0, len(products))
	for _, product := range products {
		if product.IsAvailable() {
			available = append(available, product)
		}
	}
	return available
}

func filterByKeyword(products []Product, needle string) []Product {
	matches := make([]Product, 0, len(products))
	for _, product := range products {
		if strings.Contains(strings.ToLower(product.Description), needle) {
			matches = append(matches, product)
		}
	}
	return matches
}

func toSearchResults(products []Product) []SearchResult {
	results := make([]SearchResult, 0, len(products))
	for _, product := range products {
		results = append(results, SearchResult{
			Ref:         product.Ref,
			Description: product.Description,
			Available:   product.IsAvailable(),
			Price:       product.Price,
		})
	}
	return results
}

func indexByRef(products []Product) map[int]Product {
	byRef := make(map[int]Product, len(products))
	for _, product := range products {
		byRef[product.Ref] = product
	}
	return byRef
}
