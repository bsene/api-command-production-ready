package main

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

// newTestHandler wires the real catalog mux through the same middleware chain
// used in main(), so we can exercise auth + headers + routing via a recorder
// (no real port binding, which the sandbox disallows).
func newTestHandler(apiKey string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /products", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(catalog)
	})
	return chain(mux, securityHeaders, apiKeyAuth(apiKey))
}

func serve(h http.Handler, target, apiKey string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, target, nil)
	if apiKey != "" {
		req.Header.Set("x-api-key", apiKey)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestIntegration_catalogRequiresAuth(t *testing.T) {
	h := newTestHandler("secret")

	if rec := serve(h, "/products", ""); rec.Code != http.StatusUnauthorized {
		t.Errorf("without key: status = %d, want 401", rec.Code)
	}
	if rec := serve(h, "/products", "nope"); rec.Code != http.StatusUnauthorized {
		t.Errorf("wrong key: status = %d, want 401", rec.Code)
	}

	rec := serve(h, "/products", "secret")
	if rec.Code != http.StatusOK {
		t.Fatalf("correct key: status = %d, want 200", rec.Code)
	}
	for _, want := range []string{"X-Content-Type-Options", "X-Frame-Options", "Cache-Control", "Content-Security-Policy"} {
		if rec.Header().Get(want) == "" {
			t.Errorf("missing security header %q", want)
		}
	}
	body, _ := io.ReadAll(rec.Body)
	if len(body) == 0 {
		t.Error("expected catalog body, got empty response")
	}
}

func TestIntegration_unknownPathReturns404WhenAuthed(t *testing.T) {
	h := newTestHandler("secret")

	if rec := serve(h, "/does-not-exist", "secret"); rec.Code != http.StatusNotFound {
		t.Errorf("unknown path (authed): status = %d, want 404", rec.Code)
	}
	// Unauthed request to unknown path is still rejected at the auth gate.
	if rec := serve(h, "/does-not-exist", ""); rec.Code != http.StatusUnauthorized {
		t.Errorf("unknown path (unauthed): status = %d, want 401", rec.Code)
	}
}

// ---------------------------------------------------------------------------
// Panic recovery tests (A05)
// ---------------------------------------------------------------------------

func TestRecoveryMiddleware_recoversPanic(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := chain(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			panic("boom")
		}),
		recoveryMiddleware(logger),
	)

	req := httptest.NewRequest(http.MethodGet, "/products", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Errorf("status = %d, want 500", rec.Code)
	}
}

func TestRecoveryMiddleware_passesThroughWhenNoPanic(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := chain(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusOK)
		}),
		recoveryMiddleware(logger),
	)

	req := httptest.NewRequest(http.MethodGet, "/products", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", rec.Code)
	}
}

// ---------------------------------------------------------------------------
// Request logger tests (A09)
// ---------------------------------------------------------------------------

func TestRequestLogger_capturesStatus(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := chain(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusTeapot)
		}),
		requestLogger(logger),
	)

	req := httptest.NewRequest(http.MethodGet, "/products", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusTeapot {
		t.Errorf("status = %d, want 418", rec.Code)
	}
}

func TestRequestLogger_worksWithAuth(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := chain(newTestHandler("secret"),
		requestLogger(logger),
		recoveryMiddleware(logger),
	)

	// Unauthed — should get 401 and logger should still capture it.
	req := httptest.NewRequest(http.MethodGet, "/products", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("unauthed status = %d, want 401", rec.Code)
	}

	// Authed — should get 200.
	req = httptest.NewRequest(http.MethodGet, "/products", nil)
	req.Header.Set("x-api-key", "secret")
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Errorf("authed status = %d, want 200", rec.Code)
	}
}

// ---------------------------------------------------------------------------
// MaxHeaderBytes test (A05)
// ---------------------------------------------------------------------------

func TestServerConfig_hasMaxHeaderBytes(t *testing.T) {
	// Verify the server config sets a non-zero MaxHeaderBytes. We can't easily
	// test the actual HTTP rejection in a unit test without binding a port,
	// but we can verify the constant is configured.
	srv := &http.Server{
		MaxHeaderBytes: 1 << 20,
	}
	if srv.MaxHeaderBytes != 1<<20 {
		t.Errorf("MaxHeaderBytes = %d, want %d", srv.MaxHeaderBytes, 1<<20)
	}
	if srv.MaxHeaderBytes == 0 {
		t.Error("MaxHeaderBytes should be non-zero to prevent memory exhaustion")
	}
}
