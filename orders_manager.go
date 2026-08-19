package apicommand

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

// OrdersManager prepares sports-product orders by consuming the products API.
type OrdersManager struct {
	baseURL           string
	apiKey            string
	client            *http.Client
	allowInsecureHTTP bool
	tlsConfig         *tls.Config
	logger            *slog.Logger
}

// Option configures an OrdersManager.
type Option func(*OrdersManager)

// WithHTTPClient overrides the default HTTP client.
//
// Prefer WithTLSConfig for pinning a specific trust store; only use this when
// you need full control over transport behaviour (timeouts, proxies, …).
//
// Note: WithHTTPClient bypasses the built-in SSRF-safe dialer. Only use it in
// tests with a mock transport; in production, rely on the default SSRF-protected
// transport or WithTLSConfig.
func WithHTTPClient(client *http.Client) Option {
	return func(m *OrdersManager) { m.client = client }
}

// WithTLSConfig pins TLS verification for the products API: the supplied
// *tls.Config (typically holding a custom RootCAs pool or a pinned
// certificate) is applied to the manager's SSRF-safe HTTP transport. This
// addresses the "no TLS pinning" finding (A02) by letting callers refuse any
// chain that does not terminate in the expected root(s).
func WithTLSConfig(cfg *tls.Config) Option {
	return func(m *OrdersManager) { m.tlsConfig = cfg.Clone() }
}

// WithInsecureHTTP allows a plain http:// base URL. It is intended only for
// local development against the in-process products API fixture and is
// otherwise refused (A02 cryptographic failures: do not transmit over
// unencrypted HTTP by default).
//
// In local-dev mode loopback and private IPs are permitted at dial time so
// the fixture (127.0.0.1) works, but link-local addresses such as the cloud
// metadata endpoint 169.254.169.254 remain blocked (A10 SSRF).
func WithInsecureHTTP() Option {
	return func(m *OrdersManager) { m.allowInsecureHTTP = true }
}

// WithAPIKey sets the API key sent in the x-api-key header on every outbound
// request. Required when the products API enforces authentication (A01 broken
// access control).
func WithAPIKey(key string) Option {
	return func(m *OrdersManager) { m.apiKey = key }
}

// WithLogger overrides the default slog logger used for structured access and
// error logging (A09 security logging and monitoring failures).
func WithLogger(logger *slog.Logger) Option {
	return func(m *OrdersManager) { m.logger = logger }
}

// NewOrdersManager creates an OrdersManager targeting the given API base URL
// (e.g. "https://products.com").
//
// The base URL MUST use the https scheme unless WithInsecureHTTP is supplied;
// a plain http:// URL is rejected to avoid sending requests over an
// unencrypted channel (A02 cryptographic failures).
//
// The host is validated against blocked IP ranges (loopback, private,
// link-local/metadata) both at construction time and at dial time to prevent
// SSRF attacks (A04/A10).
func NewOrdersManager(baseURL string, opts ...Option) (*OrdersManager, error) {
	m := &OrdersManager{
		baseURL: strings.TrimRight(baseURL, "/"),
		client:  &http.Client{Timeout: 10 * time.Second},
		logger:  slog.Default(),
	}
	for _, opt := range opts {
		opt(m)
	}

	// If no custom HTTP client transport was provided, use the SSRF-safe
	// transport (with optional TLS pinning). This covers the default case
	// and the WithTLSConfig case.
	if m.client.Transport == nil {
		m.client.Transport = newSSRFSafeTransport(m.tlsConfig, m.allowInsecureHTTP)
	}

	if err := m.validateBaseURL(); err != nil {
		return nil, err
	}
	return m, nil
}

// validateBaseURL parses the base URL and enforces scheme + SSRF constraints.
func (m *OrdersManager) validateBaseURL() error {
	if m.baseURL == "" {
		return fmt.Errorf("base URL is empty")
	}

	u, err := url.Parse(m.baseURL)
	if err != nil {
		return fmt.Errorf("invalid base URL %q: %w", m.baseURL, err)
	}

	switch u.Scheme {
	case "https":
		// OK — preferred.
	case "http":
		if !m.allowInsecureHTTP {
			return fmt.Errorf("base URL %q must use https; pass WithInsecureHTTP() only for local dev", m.baseURL)
		}
	default:
		return fmt.Errorf("base URL %q must use http or https scheme", m.baseURL)
	}

	if u.Host == "" {
		return fmt.Errorf("base URL %q has no host", m.baseURL)
	}

	// SSRF: if the host is an IP literal, check it immediately. Hostnames
	// are resolved and checked at dial time to prevent DNS rebinding.
	if host := u.Hostname(); host != "" {
		if ip := net.ParseIP(host); ip != nil {
			if err := checkSSRFIP(ip, m.allowInsecureHTTP); err != nil {
				return err
			}
		}
	}

	return nil
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
//
// It rejects zero or negative quantities to prevent business-logic abuse where a
// negative quantity reduces or zeroes the cart total (A04 insecure design).
func (m *OrdersManager) ValidateCart(ctx context.Context, cart []CartItem) (CartValidation, error) {
	products, err := m.fetchProducts(ctx)
	if err != nil {
		return CartValidation{}, err
	}
	byRef := indexByRef(products)

	errs := &InvalidCartError{Code: http.StatusUnprocessableEntity}
	for _, item := range cart {
		// Reject zero or negative quantities first — before checking stock
		// — so a negative quantity can never reduce the total (A04).
		if item.Quantity <= 0 {
			errs.Details = append(errs.Details, CartItemIssue{
				Ref:       item.Ref,
				Requested: item.Quantity,
				Available: 0,
				Reason:    CartItemInvalidQuantity,
			})
			continue
		}

		product, ok := byRef[item.Ref]
		if !ok {
			errs.Details = append(errs.Details, CartItemIssue{
				Ref:       item.Ref,
				Requested: item.Quantity,
				Available: 0,
				Reason:    CartItemNotAvailable,
			})
			continue
		}
		if product.Stock < item.Quantity {
			errs.Details = append(errs.Details, CartItemIssue{
				Ref:       item.Ref,
				Requested: item.Quantity,
				Available: product.Stock,
				Reason:    CartItemInsufficientStock,
			})
		}
	}

	if len(errs.Details) > 0 {
		m.logger.Warn("cart validation failed",
			"item_count", len(cart),
			"invalid_count", len(errs.Details),
			"details", errs.Details)
		return CartValidation{}, errs
	}

	var totalPrice float64
	for _, item := range cart {
		product := byRef[item.Ref]
		totalPrice += product.Price * float64(item.Quantity)
	}
	return CartValidation{Valid: true, TotalPrice: totalPrice}, nil
}

func (m *OrdersManager) fetchProducts(ctx context.Context) ([]Product, error) {
	start := time.Now()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, m.baseURL+"/products", nil)
	if err != nil {
		m.logger.Error("building products request failed",
			"base_url", m.baseURL, "error", err)
		return nil, fmt.Errorf("building products request: %w", err)
	}
	if m.apiKey != "" {
		req.Header.Set("x-api-key", m.apiKey)
	}

	resp, err := m.client.Do(req)
	if err != nil {
		m.logger.Error("requesting products failed",
			"url", req.URL.String(), "elapsed", time.Since(start), "error", err)
		return nil, fmt.Errorf("requesting products: %w", err)
	}
	defer resp.Body.Close()

	elapsed := time.Since(start)

	if resp.StatusCode != http.StatusOK {
		m.logger.Warn("products API returned non-OK status",
			"url", req.URL.String(), "status", resp.StatusCode, "elapsed", elapsed)
		return nil, fmt.Errorf("products API returned status %d", resp.StatusCode)
	}

	var products []Product
	if err := json.NewDecoder(resp.Body).Decode(&products); err != nil {
		m.logger.Error("decoding products response failed",
			"url", req.URL.String(), "status", resp.StatusCode, "error", err)
		return nil, fmt.Errorf("decoding products: %w", err)
	}

	m.logger.Info("products request completed",
		"url", req.URL.String(), "status", resp.StatusCode,
		"product_count", len(products), "elapsed", elapsed)

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

// ---------------------------------------------------------------------------
// SSRF protection (A04 insecure design / A10 server-side request forgery)
// ---------------------------------------------------------------------------

// newSSRFSafeTransport returns an *http.Transport whose DialContext resolves
// the hostname and rejects any IP that falls in a blocked range before
// connecting. This prevents SSRF attacks — including DNS-rebinding, where a
// hostname resolves to a public IP at validation time but a private/metadata
// IP at request time.
func newSSRFSafeTransport(tlsCfg *tls.Config, allowLocalDev bool) *http.Transport {
	dialer := &net.Dialer{
		Timeout:   5 * time.Second,
		KeepAlive: 30 * time.Second,
	}
	t := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, fmt.Errorf("split host:port: %w", err)
			}
			ips, err := net.DefaultResolver.LookupIPAddr(ctx, host)
			if err != nil {
				return nil, fmt.Errorf("resolve %s: %w", host, err)
			}
			for _, ipAddr := range ips {
				if err := checkSSRFIP(ipAddr.IP, allowLocalDev); err != nil {
					return nil, err
				}
			}
			// Dial the first verified-safe IP directly to avoid a second
			// resolution that could return a different (blocked) address.
			return dialer.DialContext(ctx, network, net.JoinHostPort(ips[0].IP.String(), port))
		},
	}
	if tlsCfg != nil {
		t.TLSClientConfig = tlsCfg
	}
	return t
}

// checkSSRFIP returns an error if the IP falls in a range that must never be
// the target of an outbound HTTP request from the OrdersManager.
//
// Blocked ranges:
//   - Link-local unicast/multicast (169.254.0.0/16, fe80::/10) — includes the
//     cloud metadata endpoint 169.254.169.254 (AWS/GCP/Azure IMDS).
//   - Unspecified (0.0.0.0, ::).
//   - Multicast (224.0.0.0/4, ff00::/8).
//
// When allowLocalDev is false (the default, HTTPS mode) loopback and private
// ranges are also blocked. When allowLocalDev is true (WithInsecureHTTP,
// local-dev fixture) loopback and private IPs are permitted so the in-process
// fixture on 127.0.0.1 works, but link-local/metadata remains blocked.
func checkSSRFIP(ip net.IP, allowLocalDev bool) error {
	if ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() {
		return fmt.Errorf("SSRF protection: %s is a link-local address (cloud metadata risk, A10)", ip)
	}
	if ip.IsUnspecified() {
		return fmt.Errorf("SSRF protection: %s is an unspecified address", ip)
	}
	if ip.IsMulticast() {
		return fmt.Errorf("SSRF protection: %s is a multicast address", ip)
	}
	if allowLocalDev {
		return nil
	}
	if ip.IsLoopback() {
		return fmt.Errorf("SSRF protection: %s is a loopback address", ip)
	}
	if ip.IsPrivate() {
		return fmt.Errorf("SSRF protection: %s is a private address", ip)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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
