package apicommand

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

// fakeTransport is a mock HTTP transport: it records the outgoing request and
// returns a canned response, without binding any real network port.
type fakeTransport struct {
	status int
	body   string
	delay  time.Duration
	seen   *http.Request
}

func (t *fakeTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	t.seen = req
	if t.delay > 0 {
		select {
		case <-req.Context().Done():
			return nil, req.Context().Err()
		case <-time.After(t.delay):
		}
	}
	return &http.Response{
		StatusCode: t.status,
		Body:       io.NopCloser(strings.NewReader(t.body)),
		Header:     make(http.Header),
	}, nil
}

func productsJSON(t *testing.T, products []Product) string {
	t.Helper()
	data, err := json.Marshal(products)
	if err != nil {
		t.Fatalf("marshal products: %v", err)
	}
	return string(data)
}

func managerWithTransport(t *testing.T, status int, body string) (*OrdersManager, *fakeTransport) {
	t.Helper()
	transport := &fakeTransport{status: status, body: body}
	client := &http.Client{Transport: transport}
	m, err := NewOrdersManager("https://products.com", WithHTTPClient(client))
	if err != nil {
		t.Fatalf("NewOrdersManager: %v", err)
	}
	return m, transport
}

func sampleProducts() []Product {
	return []Product{
		{Ref: 1, Description: "vélo électrique", Stock: 10, Price: 1400},
		{Ref: 2, Description: "balle de tennis", Stock: 1000, Price: 1.5},
		{Ref: 3, Description: "raquette de tennis", Stock: 0, Price: 80},
		{Ref: 4, Description: "ballon de football", Stock: 5, Price: 25},
	}
}

func TestFetchProducts_buildsCorrectRequest(t *testing.T) {
	manager, transport := managerWithTransport(t, http.StatusOK, productsJSON(t, sampleProducts()))

	if _, err := manager.AllDescriptions(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if transport.seen.Method != http.MethodGet {
		t.Errorf("request method = %q, want GET", transport.seen.Method)
	}
	if transport.seen.URL.String() != "https://products.com/products" {
		t.Errorf("request URL = %q, want https://products.com/products", transport.seen.URL.String())
	}
}

func TestAllDescriptions(t *testing.T) {
	manager, _ := managerWithTransport(t, http.StatusOK, productsJSON(t, sampleProducts()))

	got, err := manager.AllDescriptions(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	want := []string{"balle de tennis", "ballon de football", "raquette de tennis", "vélo électrique"}
	if !equalStrings(got, want) {
		t.Errorf("AllDescriptions = %v, want %v", got, want)
	}
}

func TestAvailableDescriptions(t *testing.T) {
	manager, _ := managerWithTransport(t, http.StatusOK, productsJSON(t, sampleProducts()))

	got, err := manager.AvailableDescriptions(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	want := []string{"balle de tennis", "ballon de football", "vélo électrique"}
	if !equalStrings(got, want) {
		t.Errorf("AvailableDescriptions = %v, want %v", got, want)
	}
}

func TestIsAvailable(t *testing.T) {
	manager, _ := managerWithTransport(t, http.StatusOK, productsJSON(t, sampleProducts()))

	tests := []struct {
		name string
		ref  int
		want bool
	}{
		{"in stock", 1, true},
		{"out of stock", 3, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := manager.IsAvailable(context.Background(), tt.ref)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tt.want {
				t.Errorf("IsAvailable(%d) = %v, want %v", tt.ref, got, tt.want)
			}
		})
	}
}

func TestIsAvailable_unknownRef_returnsError(t *testing.T) {
	manager, _ := managerWithTransport(t, http.StatusOK, productsJSON(t, sampleProducts()))

	if _, err := manager.IsAvailable(context.Background(), 999); err == nil {
		t.Fatal("expected error for unknown ref, got nil")
	}
}

func TestSearch(t *testing.T) {
	manager, _ := managerWithTransport(t, http.StatusOK, productsJSON(t, sampleProducts()))

	got, err := manager.Search(context.Background(), "tennis")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(got) != 2 {
		t.Fatalf("Search returned %d results, want 2", len(got))
	}

	byRef := make(map[int]SearchResult, len(got))
	for _, r := range got {
		byRef[r.Ref] = r
	}

	balle := byRef[2]
	if !balle.Available || balle.Price != 1.5 {
		t.Errorf("balle de tennis result = %+v, want available at 1.5", balle)
	}
	raquette := byRef[3]
	if raquette.Available || raquette.Price != 80 {
		t.Errorf("raquette de tennis result = %+v, want unavailable at 80", raquette)
	}
}

func TestSearch_caseInsensitive(t *testing.T) {
	manager, _ := managerWithTransport(t, http.StatusOK, productsJSON(t, sampleProducts()))

	got, err := manager.Search(context.Background(), "TENNIS")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 2 {
		t.Errorf("Search(TENNIS) returned %d results, want 2", len(got))
	}
}

func TestSearch_noMatch(t *testing.T) {
	manager, _ := managerWithTransport(t, http.StatusOK, productsJSON(t, sampleProducts()))

	got, err := manager.Search(context.Background(), "surf")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("Search(surf) returned %d results, want 0", len(got))
	}
}

func TestValidateCart(t *testing.T) {
	manager, _ := managerWithTransport(t, http.StatusOK, productsJSON(t, sampleProducts()))

	tests := []struct {
		name      string
		cart      []CartItem
		wantOK    bool
		wantTotal float64
		wantCode  int
	}{
		{
			name:      "valid cart",
			cart:      []CartItem{{Ref: 1, Quantity: 2}, {Ref: 2, Quantity: 3}},
			wantOK:    true,
			wantTotal: 1400*2 + 1.5*3,
		},
		{
			name:      "empty cart is valid at zero",
			cart:      []CartItem{},
			wantOK:    true,
			wantTotal: 0,
		},
		{
			name:     "out of stock product",
			cart:     []CartItem{{Ref: 3, Quantity: 1}},
			wantOK:   false,
			wantCode: http.StatusUnprocessableEntity,
		},
		{
			name:     "quantity exceeds stock",
			cart:     []CartItem{{Ref: 1, Quantity: 100}},
			wantOK:   false,
			wantCode: http.StatusUnprocessableEntity,
		},
		{
			name:     "unknown product",
			cart:     []CartItem{{Ref: 999, Quantity: 1}},
			wantOK:   false,
			wantCode: http.StatusUnprocessableEntity,
		},
		{
			name:     "mixed valid and invalid",
			cart:     []CartItem{{Ref: 1, Quantity: 1}, {Ref: 3, Quantity: 1}},
			wantOK:   false,
			wantCode: http.StatusUnprocessableEntity,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := manager.ValidateCart(context.Background(), tt.cart)
			if tt.wantOK {
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				if got.Valid != true {
					t.Errorf("Valid = false, want true")
				}
				if got.TotalPrice != tt.wantTotal {
					t.Errorf("TotalPrice = %v, want %v", got.TotalPrice, tt.wantTotal)
				}
				return
			}
			if err == nil {
				t.Fatal("expected error for invalid cart, got nil")
			}
			invalidErr, ok := err.(*InvalidCartError)
			if !ok {
				t.Fatalf("expected *InvalidCartError, got %T: %v", err, err)
			}
			if invalidErr.Code != tt.wantCode {
				t.Errorf("error Code = %d, want %d", invalidErr.Code, tt.wantCode)
			}
			if len(invalidErr.Details) == 0 {
				t.Error("expected at least one detail in InvalidCartError")
			}
		})
	}
}

func TestFetchProducts_errorStatus(t *testing.T) {
	manager, _ := managerWithTransport(t, http.StatusInternalServerError, "boom")

	if _, err := manager.AllDescriptions(context.Background()); err == nil {
		t.Fatal("expected error on 500, got nil")
	}
}

func TestFetchProducts_invalidJSON(t *testing.T) {
	manager, _ := managerWithTransport(t, http.StatusOK, "not json")

	if _, err := manager.AllDescriptions(context.Background()); err == nil {
		t.Fatal("expected error on invalid JSON, got nil")
	}
}

func TestFetchProducts_cancelledContext(t *testing.T) {
	transport := &fakeTransport{status: http.StatusOK, body: productsJSON(t, sampleProducts()), delay: 50 * time.Millisecond}
	client := &http.Client{Transport: transport}
	manager, err := NewOrdersManager("https://products.com", WithHTTPClient(client))
	if err != nil {
		t.Fatalf("NewOrdersManager: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Millisecond)
	defer cancel()

	if _, err := manager.AllDescriptions(ctx); err == nil {
		t.Fatal("expected error on cancelled context, got nil")
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestNewOrdersManager_rejectsHTTPByDefault(t *testing.T) {
	if _, err := NewOrdersManager("http://products.com"); err == nil {
		t.Fatal("expected error for http:// base URL, got nil")
	}
}

func TestNewOrdersManager_rejectsEmptyBaseURL(t *testing.T) {
	if _, err := NewOrdersManager(""); err == nil {
		t.Fatal("expected error for empty base URL, got nil")
	}
}

func TestNewOrdersManager_allowsHTTPWithInsecureOptIn(t *testing.T) {
	m, err := NewOrdersManager("http://127.0.0.1:18080", WithInsecureHTTP())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.HasPrefix(m.baseURL, "http://") {
		t.Errorf("baseURL = %q, want http:// scheme", m.baseURL)
	}
}

func TestNewOrdersManager_acceptsHTTPS(t *testing.T) {
	if _, err := NewOrdersManager("https://products.com"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestWithTLSConfig_appliesPinnedTransport(t *testing.T) {
	cfg := &tls.Config{MinVersion: tls.VersionTLS13}
	m, err := NewOrdersManager("https://products.com", WithTLSConfig(cfg))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	tr, ok := m.client.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("transport = %T, want *http.Transport", m.client.Transport)
	}
	if tr.TLSClientConfig == nil || tr.TLSClientConfig.MinVersion != tls.VersionTLS13 {
		t.Errorf("TLS config not applied: %+v", tr.TLSClientConfig)
	}
	// The pinned config must be a clone, not the caller's pointer.
	if tr.TLSClientConfig == cfg {
		t.Error("WithTLSConfig should clone the supplied *tls.Config, not reuse it")
	}
}

// ---------------------------------------------------------------------------
// SSRF protection tests (A04 / A10)
// ---------------------------------------------------------------------------

func TestNewOrdersManager_rejectsMetadataIP(t *testing.T) {
	// 169.254.169.254 — AWS/GCP/Azure cloud metadata endpoint.
	if _, err := NewOrdersManager("https://169.254.169.254"); err == nil {
		t.Fatal("expected error for cloud metadata IP, got nil")
	}
}

func TestNewOrdersManager_rejectsMetadataIP_overHTTPWithInsecure(t *testing.T) {
	// Link-local must be blocked even in local-dev mode.
	if _, err := NewOrdersManager("http://169.254.169.254", WithInsecureHTTP()); err == nil {
		t.Fatal("expected error for link-local IP even with WithInsecureHTTP, got nil")
	}
}

func TestNewOrdersManager_rejectsPrivateIP(t *testing.T) {
	cases := []string{
		"https://10.0.0.1",
		"https://172.16.0.1",
		"https://192.168.1.1",
	}
	for _, baseURL := range cases {
		t.Run(baseURL, func(t *testing.T) {
			if _, err := NewOrdersManager(baseURL); err == nil {
				t.Fatalf("expected error for private IP %s, got nil", baseURL)
			}
		})
	}
}

func TestNewOrdersManager_rejectsLoopbackHTTPS(t *testing.T) {
	// Loopback is blocked in default (HTTPS) mode.
	if _, err := NewOrdersManager("https://127.0.0.1"); err == nil {
		t.Fatal("expected error for loopback over HTTPS without WithInsecureHTTP, got nil")
	}
}

func TestNewOrdersManager_rejectsUnspecifiedIP(t *testing.T) {
	if _, err := NewOrdersManager("https://0.0.0.0"); err == nil {
		t.Fatal("expected error for unspecified IP, got nil")
	}
}

func TestNewOrdersManager_allowsLoopbackWithInsecureHTTP(t *testing.T) {
	// Loopback is allowed in local-dev mode (WithInsecureHTTP).
	m, err := NewOrdersManager("http://127.0.0.1:18080", WithInsecureHTTP())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if m == nil {
		t.Fatal("expected non-nil manager")
	}
}

func TestNewOrdersManager_rejectsInvalidScheme(t *testing.T) {
	if _, err := NewOrdersManager("ftp://products.com"); err == nil {
		t.Fatal("expected error for ftp:// scheme, got nil")
	}
}

func TestCheckSSRFIP_blocksMetadataAlways(t *testing.T) {
	cases := []net.IP{
		net.ParseIP("169.254.169.254"),
		net.ParseIP("fe80::1"),
	}
	for _, ip := range cases {
		t.Run(ip.String(), func(t *testing.T) {
			// Blocked even with allowLocalDev=true
			if err := checkSSRFIP(ip, true); err == nil {
				t.Errorf("expected link-local %s blocked even in local-dev mode", ip)
			}
			if err := checkSSRFIP(ip, false); err == nil {
				t.Errorf("expected link-local %s blocked in production mode", ip)
			}
		})
	}
}

func TestCheckSSRFIP_allowsLoopbackInLocalDevOnly(t *testing.T) {
	loopback := net.ParseIP("127.0.0.1")
	if err := checkSSRFIP(loopback, true); err != nil {
		t.Errorf("loopback should be allowed in local-dev mode: %v", err)
	}
	if err := checkSSRFIP(loopback, false); err == nil {
		t.Error("loopback should be blocked in production mode")
	}
}

func TestCheckSSRFIP_allowsPublicIP(t *testing.T) {
	public := net.ParseIP("93.184.216.34") // example.com
	if err := checkSSRFIP(public, false); err != nil {
		t.Errorf("public IP should be allowed: %v", err)
	}
}

// ---------------------------------------------------------------------------
// API key tests (A01 client-side auth)
// ---------------------------------------------------------------------------

func TestFetchProducts_sendsAPIKeyHeader(t *testing.T) {
	transport := &fakeTransport{status: http.StatusOK, body: productsJSON(t, sampleProducts())}
	client := &http.Client{Transport: transport}
	m, err := NewOrdersManager("https://products.com", WithHTTPClient(client), WithAPIKey("secret-key"))
	if err != nil {
		t.Fatalf("NewOrdersManager: %v", err)
	}

	if _, err := m.AllDescriptions(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	got := transport.seen.Header.Get("x-api-key")
	if got != "secret-key" {
		t.Errorf("x-api-key header = %q, want %q", got, "secret-key")
	}
}

func TestFetchProducts_omitsAPIKeyWhenNotSet(t *testing.T) {
	transport := &fakeTransport{status: http.StatusOK, body: productsJSON(t, sampleProducts())}
	client := &http.Client{Transport: transport}
	m, err := NewOrdersManager("https://products.com", WithHTTPClient(client))
	if err != nil {
		t.Fatalf("NewOrdersManager: %v", err)
	}

	if _, err := m.AllDescriptions(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if got := transport.seen.Header.Get("x-api-key"); got != "" {
		t.Errorf("x-api-key header = %q, want empty (not set)", got)
	}
}

// ---------------------------------------------------------------------------
// Negative / zero quantity validation tests (A04)
// ---------------------------------------------------------------------------

func TestValidateCart_rejectsNegativeQuantity(t *testing.T) {
	manager, _ := managerWithTransport(t, http.StatusOK, productsJSON(t, sampleProducts()))

	cart := []CartItem{{Ref: 1, Quantity: -2}}
	_, err := manager.ValidateCart(context.Background(), cart)
	if err == nil {
		t.Fatal("expected error for negative quantity, got nil")
	}
	invalidErr, ok := err.(*InvalidCartError)
	if !ok {
		t.Fatalf("expected *InvalidCartError, got %T: %v", err, err)
	}
	if len(invalidErr.Details) != 1 {
		t.Fatalf("expected 1 detail, got %d", len(invalidErr.Details))
	}
	d := invalidErr.Details[0]
	if d.Reason != CartItemInvalidQuantity {
		t.Errorf("reason = %d, want CartItemInvalidQuantity (%d)", d.Reason, CartItemInvalidQuantity)
	}
	if d.Requested != -2 {
		t.Errorf("requested = %d, want -2", d.Requested)
	}
}

func TestValidateCart_rejectsZeroQuantity(t *testing.T) {
	manager, _ := managerWithTransport(t, http.StatusOK, productsJSON(t, sampleProducts()))

	cart := []CartItem{{Ref: 1, Quantity: 0}}
	_, err := manager.ValidateCart(context.Background(), cart)
	if err == nil {
		t.Fatal("expected error for zero quantity, got nil")
	}
	invalidErr, ok := err.(*InvalidCartError)
	if !ok {
		t.Fatalf("expected *InvalidCartError, got %T: %v", err, err)
	}
	if invalidErr.Details[0].Reason != CartItemInvalidQuantity {
		t.Errorf("reason = %d, want CartItemInvalidQuantity", invalidErr.Details[0].Reason)
	}
}

func TestValidateCart_rejectsNegativeQuantityDoesNotReduceTotal(t *testing.T) {
	manager, _ := managerWithTransport(t, http.StatusOK, productsJSON(t, sampleProducts()))

	// A negative quantity must not produce a valid cart with a reduced total.
	cart := []CartItem{{Ref: 1, Quantity: 2}, {Ref: 2, Quantity: -5}}
	result, err := manager.ValidateCart(context.Background(), cart)
	if err == nil {
		t.Fatalf("expected error for mixed cart with negative qty, got valid result: %+v", result)
	}
}

func TestValidateCart_negativeAndValidMixed(t *testing.T) {
	manager, _ := managerWithTransport(t, http.StatusOK, productsJSON(t, sampleProducts()))

	cart := []CartItem{{Ref: 1, Quantity: 1}, {Ref: 2, Quantity: -3}, {Ref: 3, Quantity: 1}}
	_, err := manager.ValidateCart(context.Background(), cart)
	if err == nil {
		t.Fatal("expected error for mixed cart, got nil")
	}
	invalidErr, ok := err.(*InvalidCartError)
	if !ok {
		t.Fatalf("expected *InvalidCartError, got %T", err)
	}
	// Should report the negative quantity AND the out-of-stock item.
	if len(invalidErr.Details) != 2 {
		t.Errorf("expected 2 issues (invalid qty + out of stock), got %d", len(invalidErr.Details))
	}
}

// ---------------------------------------------------------------------------
// Quantity type + CartItem.Validate tests (A04 prevention)
// ---------------------------------------------------------------------------

func TestNewQuantity_rejectsNonPositive(t *testing.T) {
	for _, n := range []int{-5, -1, 0} {
		q, err := NewQuantity(n)
		if err == nil {
			t.Errorf("NewQuantity(%d) = %v, want error", n, q)
		}
	}
}

func TestNewQuantity_acceptsPositive(t *testing.T) {
	q, err := NewQuantity(7)
	if err != nil {
		t.Fatalf("NewQuantity(7): unexpected error: %v", err)
	}
	if q.Int() != 7 {
		t.Errorf("NewQuantity(7).Int() = %d, want 7", q.Int())
	}
}

func TestCartItem_Validate_rejectsNonPositive(t *testing.T) {
	for _, qty := range []Quantity{-3, 0} {
		item := CartItem{Ref: 1, Quantity: qty}
		if err := item.Validate(); err == nil {
			t.Errorf("CartItem{Quantity: %d}.Validate() = nil, want error", qty)
		}
	}
}

func TestCartItem_Validate_acceptsPositive(t *testing.T) {
	item := CartItem{Ref: 1, Quantity: 2}
	if err := item.Validate(); err != nil {
		t.Errorf("CartItem{Quantity: 2}.Validate() = %v, want nil", err)
	}
}
