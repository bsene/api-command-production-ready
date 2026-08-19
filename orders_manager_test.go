package apicommand

import (
	"context"
	"encoding/json"
	"io"
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
	return NewOrdersManager("https://products.com", WithHTTPClient(client)), transport
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
		wantValid bool
		wantTotal float64
	}{
		{
			name:      "valid cart",
			cart:      []CartItem{{Ref: 1, Quantity: 2}, {Ref: 2, Quantity: 3}},
			wantValid: true,
			wantTotal: 1400*2 + 1.5*3,
		},
		{
			name:      "out of stock product",
			cart:      []CartItem{{Ref: 3, Quantity: 1}},
			wantValid: false,
			wantTotal: 0,
		},
		{
			name:      "quantity exceeds stock",
			cart:      []CartItem{{Ref: 1, Quantity: 100}},
			wantValid: false,
			wantTotal: 0,
		},
		{
			name:      "unknown product",
			cart:      []CartItem{{Ref: 999, Quantity: 1}},
			wantValid: false,
			wantTotal: 0,
		},
		{
			name:      "mixed valid and invalid",
			cart:      []CartItem{{Ref: 1, Quantity: 1}, {Ref: 3, Quantity: 1}},
			wantValid: false,
			wantTotal: 1400, // only the valid item contributes
		},
		{
			name:      "empty cart is valid at zero",
			cart:      []CartItem{},
			wantValid: true,
			wantTotal: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := manager.ValidateCart(context.Background(), tt.cart)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got.Valid != tt.wantValid {
				t.Errorf("Valid = %v, want %v", got.Valid, tt.wantValid)
			}
			if got.TotalPrice != tt.wantTotal {
				t.Errorf("TotalPrice = %v, want %v", got.TotalPrice, tt.wantTotal)
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
	manager := NewOrdersManager("https://products.com", WithHTTPClient(client))

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
