package apicommand

// =============================================================================
// Smoke / acceptance tests — QA ownership
// =============================================================================
//
// Audience: QA engineers.
//
// These tests are NOT unit tests. They do not stub the HTTP client. Each
// scenario boots a REAL HTTP server on a live port and drives the public
// OrdersManager API exactly the way the application would, over a real socket.
// They exist to answer one question:
//
//     "If we deploy this, does it actually talk to a running products API?"
//
// Scope (what we assert at the smoke level):
//   1. The client can reach a live server and read back product data.
//   2. Each public feature behaves correctly end-to-end over the wire.
//   3. Server-side failures surface as errors (the client does not silently
//      succeed when the API is broken).
//
// How to run just the smoke suite:
//
//     go test -run TestSmoke -v ./...
//
// Reference product catalog used across scenarios (a stable, known fixture so
// expected values are predictable):
//
//   ref | description           | stock | price
//   ----+-----------------------+-------+-------
//    1  | vélo électrique        |  10   | 1400
//    2  | balle de tennis        | 1000  | 1.5
//    3  | raquette de tennis     |   0   | 80
//    4  | ballon de football     |   5   | 25
//
// =============================================================================

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// --- QA test harness ---------------------------------------------------------

// startProductsAPI stands up a live HTTP server that emulates the products API
// for one test scenario, serving the provided catalog on GET /products. It
// returns an OrdersManager wired to that server's real URL. The server is
// torn down automatically when the scenario ends.
//
// This is the only piece of "plumbing" in this file; everything below it is
// written as readable scenarios.
func startProductsAPI(t *testing.T, catalog []Product) *OrdersManager {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/products" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(catalog); err != nil {
			t.Errorf("test harness failed to encode catalog: %v", err)
		}
	}))
	t.Cleanup(server.Close)
	return NewOrdersManager(server.URL)
}

// startBrokenAPI stands up a live HTTP server that always answers GET /products
// with HTTP 500, to simulate an API outage.
func startBrokenAPI(t *testing.T) *OrdersManager {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "internal server error", http.StatusInternalServerError)
	}))
	t.Cleanup(server.Close)
	return NewOrdersManager(server.URL)
}

// --- Smoke scenarios ---------------------------------------------------------

// Scenario: list all product descriptions against a live API.
//
//   Given the products API is running and returns the reference catalog
//   When  the client requests all product descriptions
//   Then  every description is returned, sorted alphabetically.
func TestSmoke_ListAllDescriptions(t *testing.T) {
	orders := startProductsAPI(t, qaCatalog())

	got, err := orders.AllDescriptions(context.Background())
	if err != nil {
		t.Fatalf("FAIL: could not retrieve descriptions from the live API: %v", err)
	}

	want := []string{"balle de tennis", "ballon de football", "raquette de tennis", "vélo électrique"}
	if !equalStrings(got, want) {
		t.Errorf("FAIL: descriptions returned = %v, expected = %v (alphabetical order)", got, want)
	}
}

// Scenario: list only available (in-stock) product descriptions.
//
//   Given the products API is running and returns the reference catalog
//    And the "raquette de tennis" product is out of stock (stock = 0)
//   When  the client requests available product descriptions
//   Then  out-of-stock products are excluded
//    And the remaining descriptions are returned, sorted alphabetically.
func TestSmoke_ListOnlyAvailableDescriptions(t *testing.T) {
	orders := startProductsAPI(t, qaCatalog())

	got, err := orders.AvailableDescriptions(context.Background())
	if err != nil {
		t.Fatalf("FAIL: could not retrieve available descriptions from the live API: %v", err)
	}

	want := []string{"balle de tennis", "ballon de football", "vélo électrique"}
	if !equalStrings(got, want) {
		t.Errorf("FAIL: available descriptions returned = %v, expected = %v (no out-of-stock items)", got, want)
	}
}

// Scenario: check availability of a single product by reference.
//
//   Given the products API is running and returns the reference catalog
//   When  the client checks availability of an in-stock product (ref 1)
//   Then  the product is reported as available
//   When  the client checks availability of an out-of-stock product (ref 3)
//   Then  the product is reported as not available.
func TestSmoke_CheckSingleProductAvailability(t *testing.T) {
	orders := startProductsAPI(t, qaCatalog())

	inStock, err := orders.IsAvailable(context.Background(), 1)
	if err != nil {
		t.Fatalf("FAIL: availability check for ref 1 errored: %v", err)
	}
	if !inStock {
		t.Error("FAIL: ref 1 (vélo électrique, stock 10) reported unavailable, expected available")
	}

	outOfStock, err := orders.IsAvailable(context.Background(), 3)
	if err != nil {
		t.Fatalf("FAIL: availability check for ref 3 errored: %v", err)
	}
	if outOfStock {
		t.Error("FAIL: ref 3 (raquette de tennis, stock 0) reported available, expected unavailable")
	}
}

// Scenario: search products by keyword.
//
//   Given the products API is running and returns the reference catalog
//   When  the client searches for "tennis"
//   Then  all products whose description contains "tennis" are returned
//    And each result reports its availability and price.
func TestSmoke_SearchProductsByKeyword(t *testing.T) {
	orders := startProductsAPI(t, qaCatalog())

	got, err := orders.Search(context.Background(), "tennis")
	if err != nil {
		t.Fatalf("FAIL: keyword search against the live API errored: %v", err)
	}

	if len(got) != 2 {
		t.Fatalf("FAIL: search for \"tennis\" returned %d results, expected 2 (balle + raquette)", len(got))
	}

	byRef := make(map[int]SearchResult, len(got))
	for _, r := range got {
		byRef[r.Ref] = r
	}
	if balle, ok := byRef[2]; !ok {
		t.Fatal("FAIL: search result missing ref 2 (balle de tennis)")
	} else if !balle.Available || balle.Price != 1.5 {
		t.Errorf("FAIL: balle de tennis = available=%v price=%v, expected available=true price=1.5", balle.Available, balle.Price)
	}
	if raquette, ok := byRef[3]; !ok {
		t.Fatal("FAIL: search result missing ref 3 (raquette de tennis)")
	} else if raquette.Available || raquette.Price != 80 {
		t.Errorf("FAIL: raquette de tennis = available=%v price=%v, expected available=false price=80", raquette.Available, raquette.Price)
	}
}

// Scenario: validate a customer cart against current stock.
//
//   Given the products API is running and returns the reference catalog
//   When  the client validates a cart with two in-stock items
//        (2x vélo électrique @1400, 3x balle de tennis @1.5)
//   Then  the cart is reported as valid
//    And the total price is 1400*2 + 1.5*3 = 2804.5.
func TestSmoke_ValidateCartAgainstStock(t *testing.T) {
	orders := startProductsAPI(t, qaCatalog())

	cart := []CartItem{
		{Ref: 1, Quantity: 2},
		{Ref: 2, Quantity: 3},
	}
	result, err := orders.ValidateCart(context.Background(), cart)
	if err != nil {
		t.Fatalf("FAIL: cart validation against the live API errored: %v", err)
	}
	if !result.Valid {
		t.Error("FAIL: cart reported invalid, expected valid (all items in stock)")
	}
	wantTotal := 1400*2 + 1.5*3
	if result.TotalPrice != wantTotal {
		t.Errorf("FAIL: cart total = %v, expected %v", result.TotalPrice, wantTotal)
	}
}

// Scenario: the client must fail loudly when the API is down.
//
//   Given the products API is running but returns HTTP 500 for every request
//   When  the client requests all product descriptions
//   Then  the request fails with an error (it does NOT silently return empty).
func TestSmoke_ApiOutageSurfacesAsError(t *testing.T) {
	orders := startBrokenAPI(t)

	if _, err := orders.AllDescriptions(context.Background()); err == nil {
		t.Fatal("FAIL: API returned HTTP 500 but the client reported success; an outage must surface as an error")
	}
}

// Scenario: base URL with a trailing slash must still reach /products.
//
//   Given the products API is running at http://127.0.0.1:<port>/
//   When  the client is configured with a base URL ending in "/"
//   Then  the request hits "/products" (not "//products") and succeeds.
func TestSmoke_BaseUrlTrailingSlashReachesProductsEndpoint(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/products" {
			http.NotFound(w, r)
			return
		}
		_ = json.NewEncoder(w).Encode(qaCatalog())
	}))
	t.Cleanup(server.Close)

	orders := NewOrdersManager(server.URL + "/")
	if _, err := orders.AllDescriptions(context.Background()); err != nil {
		t.Fatalf("FAIL: a trailing slash on the base URL broke the request: %v", err)
	}
}

// --- QA fixture --------------------------------------------------------------

// qaCatalog returns the stable reference catalog documented at the top of this
// file. Scenarios rely on these exact values for their expected results.
func qaCatalog() []Product {
	return []Product{
		{Ref: 1, Description: "vélo électrique", Stock: 10, Price: 1400},
		{Ref: 2, Description: "balle de tennis", Stock: 1000, Price: 1.5},
		{Ref: 3, Description: "raquette de tennis", Stock: 0, Price: 80},
		{Ref: 4, Description: "ballon de football", Stock: 5, Price: 25},
	}
}
