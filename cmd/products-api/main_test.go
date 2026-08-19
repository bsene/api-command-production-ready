package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestValidateListenAddr_loopbackAllowed(t *testing.T) {
	cases := []string{"127.0.0.1:18080", "[::1]:18080", "localhost:18080"}
	for _, addr := range cases {
		if err := validateListenAddr(addr, false); err != nil {
			t.Errorf("validateListenAddr(%q, false) = %v, want nil", addr, err)
		}
	}
}

func TestValidateListenAddr_nonLoopbackRefused(t *testing.T) {
	cases := []string{"0.0.0.0:18080", ":18080", "10.0.0.1:18080"}
	for _, addr := range cases {
		if err := validateListenAddr(addr, false); err == nil {
			t.Errorf("validateListenAddr(%q, false) = nil, want error", addr)
		}
	}
}

func TestValidateListenAddr_nonLoopbackAllowedWithOptIn(t *testing.T) {
	if err := validateListenAddr("0.0.0.0:18080", true); err != nil {
		t.Errorf("validateListenAddr(0.0.0.0:18080, true) = %v, want nil", err)
	}
}

func TestValidateListenAddr_invalidAddr(t *testing.T) {
	if err := validateListenAddr("not-an-address", false); err == nil {
		t.Fatal("expected error for malformed address, got nil")
	}
}

func TestApiKeyAuth_rejectsMissingOrWrongKey(t *testing.T) {
	h := apiKeyAuth("secret")(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	for _, tc := range []struct {
		name   string
		header string
		want   int
	}{
		{"missing", "", http.StatusUnauthorized},
		{"wrong", "nope", http.StatusUnauthorized},
		{"correct", "secret", http.StatusOK},
	} {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/products", nil)
			if tc.header != "" {
				req.Header.Set("x-api-key", tc.header)
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != tc.want {
				t.Errorf("status = %d, want %d", rec.Code, tc.want)
			}
		})
	}
}
