// Command products-api is a real HTTP server that emulates the fictional
// products API (https://products.com) from the kata.
//
// It exists so the QA smoke suite (smoke-tests/*.hurl) can run against a real
// server process instead of an in-test mock: the Taskfile boots this binary,
// runs Hurl against it, then tears it down.
package main

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"log/slog"
	"net"
	"net/http"
	"os"
	"time"
)

// product mirrors the wire format of the products API (note the French "prix"
// field for the price).
type product struct {
	Ref         int     `json:"ref"`
	Description string  `json:"description"`
	Stock       int     `json:"stock"`
	Prix        float64 `json:"prix"`
}

// catalog is the stable reference catalog served on GET /products. Smoke
// scenarios assert against these exact values, so do not change it without
// updating smoke-tests/*.hurl.
var catalog = []product{
	{Ref: 1, Description: "vélo électrique", Stock: 10, Prix: 1400},
	{Ref: 2, Description: "balle de tennis", Stock: 1000, Prix: 1.5},
	{Ref: 3, Description: "raquette de tennis", Stock: 0, Prix: 80},
	{Ref: 4, Description: "ballon de football", Stock: 5, Prix: 25},
}

func main() {
	addr := flag.String("addr", "127.0.0.1:18080", "listen address")
	apiKey := flag.String("api-key", "", "API key required in the x-api-key header; "+
		"falls back to the PRODUCTS_API_KEY env var if the flag is empty")
	allowExternal := flag.Bool("allow-external", false,
		"allow binding to a non-loopback address (the default loopback-only bind "+
			"prevents accidental exposure on a shared host)")
	tlsCert := flag.String("tls-cert", "", "path to TLS certificate (enables HTTPS when set with -tls-key)")
	tlsKey := flag.String("tls-key", "", "path to TLS private key (enables HTTPS when set with -tls-cert)")
	flag.Parse()

	if *apiKey == "" {
		*apiKey = envOr("PRODUCTS_API_KEY", "")
	}
	if *apiKey == "" {
		log.Fatal("products API: -api-key (or PRODUCTS_API_KEY) is required; " +
			"refusing to start without authentication (A01 broken access control)")
	}

	if err := validateListenAddr(*addr, *allowExternal); err != nil {
		log.Fatalf("products API: invalid listen address %q: %v", *addr, err)
	}

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	mux := http.NewServeMux()
	mux.HandleFunc("GET /products", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(catalog); err != nil {
			logger.Error("encode catalog failed", "error", err)
		}
	})

	handler := chain(mux,
		requestLogger(logger),   // outermost: capture timing + status (A09)
		recoveryMiddleware(logger), // recover panics from any downstream handler (A05)
		securityHeaders,          // baseline defensive headers (A02/A05)
		apiKeyAuth(*apiKey),      // authenticate every request (A01)
	)

	srv := &http.Server{
		Addr:              *addr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second, // primary slowloris defense (G114)
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 20, // 1 MB — prevents memory exhaustion from oversized headers (A05)
	}

	if *tlsCert != "" && *tlsKey != "" {
		logger.Info("products API starting", "addr", *addr, "tls", true)
		if err := srv.ListenAndServeTLS(*tlsCert, *tlsKey); err != nil {
			log.Fatal(err)
		}
		return
	}
	if *tlsCert != "" || *tlsKey != "" {
		log.Fatal("products API: -tls-cert and -tls-key must be set together to enable TLS")
	}

	logger.Info("products API starting", "addr", *addr, "tls", false)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

// envOr returns the value of the named env var, or fallback if unset.
func envOr(name, fallback string) string {
	if v, ok := os.LookupEnv(name); ok {
		return v
	}
	return fallback
}

// validateListenAddr rejects non-loopback hosts unless the caller explicitly
// opted in via allowExternal. This prevents the fixture from accidentally
// binding 0.0.0.0 and exposing the (otherwise local-only) catalog on a shared
// host (A01 broken access control).
func validateListenAddr(addr string, allowExternal bool) error {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("split host:port: %w", err)
	}
	if allowExternal {
		return nil
	}
	if !isLoopback(host) {
		return errors.New("non-loopback bind refused; pass -allow-external to override")
	}
	return nil
}

// isLoopback reports whether host names a loopback address.
func isLoopback(host string) bool {
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// middleware decorates an http.Handler.
type middleware func(http.Handler) http.Handler

// chain wraps h with the given middlewares, applied left-to-right (the first
// listed runs outermost).
func chain(h http.Handler, mws ...middleware) http.Handler {
	for i := len(mws) - 1; i >= 0; i-- {
		h = mws[i](h)
	}
	return h
}

// apiKeyAuth rejects requests whose x-api-key header does not match the
// configured key (constant-time comparison). This adds authentication to the
// catalog/search endpoints so they are not anonymously accessible (A01).
func apiKeyAuth(key string) middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			provided := r.Header.Get("x-api-key")
			if subtle.ConstantTimeCompare([]byte(provided), []byte(key)) != 1 {
				w.Header().Set("WWW-Authenticate", "ApiKey")
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// securityHeaders sets baseline defensive response headers (A02/A05).
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Cache-Control", "no-store")
		h.Set("Content-Security-Policy", "default-src 'none'")
		// HSTS only makes sense over HTTPS; harmless but pointless over HTTP.
		if r.TLS != nil {
			h.Set("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
		}
		next.ServeHTTP(w, r)
	})
}

// recoveryMiddleware recovers from panics in any downstream handler or
// middleware, logs the panic with a stack trace, and returns a clean 500
// instead of crashing the process (A05 security misconfiguration).
func recoveryMiddleware(logger *slog.Logger) middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				if rec := recover(); rec != nil {
					logger.Error("panic recovered",
						"method", r.Method,
						"path", r.URL.Path,
						"remote", r.RemoteAddr,
						"panic", rec,
					)
					http.Error(w, "internal server error", http.StatusInternalServerError)
				}
			}()
			next.ServeHTTP(w, r)
		})
	}
}

// statusRecorder wraps http.ResponseWriter to capture the response status
// code for access logging.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// requestLogger logs every request with method, path, status, remote address,
// and elapsed time using structured logging (A09 security logging and
// monitoring failures).
func requestLogger(logger *slog.Logger) middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(rec, r)
			logger.Info("request",
				"method", r.Method,
				"path", r.URL.Path,
				"status", rec.status,
				"remote", r.RemoteAddr,
				"elapsed_ms", time.Since(start).Milliseconds(),
			)
		})
	}
}
