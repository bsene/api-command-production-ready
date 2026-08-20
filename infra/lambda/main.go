// Package main is the custom-runtime AWS Lambda handler for api-command.
//
// It targets the "provided.al2023" custom runtime: the Go program is compiled
// to a binary named "bootstrap" (GOOS=linux, GOARCH=arm64), zipped, and
// deployed as the Lambda code. aws-lambda-go drives the Lambda Runtime API.
//
// The handler is wired to a Lambda Function URL, which delivers the request as
// an API Gateway v2 (HTTP API) payload-format-2.0 event — the raw HTTP body
// lives in event.Body, not in the top-level event.
//
// Authentication (A01 broken access control):
//
// Although the Function URL uses authorizationType "NONE" (so AWS does not
// enforce IAM SigV4 signing), the handler itself authenticates every request
// by comparing the x-api-key header against the LAMBDA_API_KEY environment
// variable (constant-time comparison). Requests without a matching key are
// rejected with 401 before any business logic runs. The key is injected as a
// Pulumi config secret at deploy time — it never appears in source.
package main

import (
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strings"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
)

// Request is the JSON body accepted by the handler.
type Request struct {
	Ref         int     `json:"ref,omitempty"`
	Description string  `json:"description,omitempty"`
	Stock       int     `json:"stock,omitempty"`
	Price       float64 `json:"price,omitempty"`
}

// Response is returned to the caller as the HTTP response body.
type Response struct {
	OK      bool   `json:"ok"`
	Ref     int    `json:"ref"`
	Message string `json:"message"`
}

// catalogProduct mirrors the product-catalog reference data shipped via the
// Lambda layer (infra/catalog/products.json). JSON keys match the products API
// wire format — note the French "prix" field for the price, consistent with the
// fixture (cmd/products-api) and the root apicommand.Product type. This is a
// separate Go module, so the struct is duplicated here rather than imported.
type catalogProduct struct {
	Ref         int     `json:"ref"`
	Description string  `json:"description"`
	Stock       int     `json:"stock"`
	Price       float64 `json:"prix"`
}

// logger is initialized in main() so tests can inspect log output via the
// default handler if needed.
var logger *slog.Logger

// apiKey is the expected API key, read once from LAMBDA_API_KEY at startup.
var apiKey string

// catalog is the product-catalog reference loaded at startup from the Lambda
// layer (/opt/catalog/products.json by default). It is groundwork for a future
// lookup-by-ref feature — the handler does not currently use it, so a missing
// or unreadable layer is non-fatal: loadCatalog logs a warning and leaves the
// slice empty rather than crashing every invocation.
var catalog []catalogProduct

// catalogPath is the location the layer mounts the reference catalog. It can be
// overridden via the CATALOG_PATH env var for local testing.
const catalogPath = "/opt/catalog/products.json"

// handle processes a single Function URL invocation.
//
// It first authenticates the request via the x-api-key header, then
// deserializes the JSON body and returns the availability result.
func handle(ctx context.Context, event events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
	// --- Authentication (A01) ----------------------------------------------

	// Reject if no API key was configured at deploy time, or if the key is too
	// short to resist brute-force. This is a deployment misconfiguration, not a
	// caller error — log it and return 500 so the operator notices immediately
	// rather than silently allowing all traffic through. The Pulumi program
	// enforces the same >=32-byte rule at deploy time; this is defense-in-depth.
	if len(apiKey) < 32 {
		logger.Error("LAMBDA_API_KEY missing or too short — refusing to serve with a weak key",
			"key_bytes", len(apiKey),
		)
		return jsonError(500, "internal server error"), nil
	}

	provided := event.Headers["x-api-key"]
	if subtle.ConstantTimeCompare([]byte(provided), []byte(apiKey)) != 1 {
		logger.Info("unauthorized request",
			"path", event.RawPath,
			"method", event.RequestContext.HTTP.Method,
		)
		return jsonError(401, "unauthorized"), nil
	}

	// --- GET /products: serve the product catalog ---------------------------

	// The reference catalog loaded from the Lambda layer (infra/catalog/products.json)
	// is served on GET /products, mirroring the local fixture. This makes the
	// catalog a real, reachable production endpoint rather than loader groundwork.
	if event.RequestContext.HTTP.Method == http.MethodGet &&
		strings.Trim(event.RawPath, "/") == "products" {
		return serveCatalog(), nil
	}

	// --- Business logic ----------------------------------------------------

	// Guard: a GET request or a bodyless POST delivers an empty event.Body.
	// json.Unmarshal("") returns "unexpected end of JSON input", which is a
	// confusing 400 message. Return a clearer error so the caller knows they
	// must send a JSON body.
	if strings.TrimSpace(event.Body) == "" {
		return jsonError(400, "missing request body"), nil
	}

	// A proxy or client may base64-encode the body (event.IsBase64Encoded).
	// Decode before unmarshalling so encoded bodies parse instead of 400-ing.
	body := event.Body
	if event.IsBase64Encoded {
		decoded, err := base64.StdEncoding.DecodeString(body)
		if err != nil {
			return jsonError(400, "request body is not valid base64"), nil
		}
		body = string(decoded)
	}

	var req Request
	if err := json.Unmarshal([]byte(body), &req); err != nil {
		return jsonError(400, "invalid request body"), nil
	}

	// Validate bounded, non-negative fields before processing. Description is
	// echoed into the response, so cap it to bound memory amplification; price
	// and ref are domain quantities that must not be negative.
	const maxDescriptionBytes = 1024
	if len(req.Description) > maxDescriptionBytes {
		return jsonError(400, "description exceeds 1KB"), nil
	}
	if req.Price < 0 {
		return jsonError(400, "price must be >= 0"), nil
	}
	if req.Ref < 0 {
		return jsonError(400, "ref must be >= 0"), nil
	}

	available := req.Stock > 0
	resp := Response{
		OK:  available,
		Ref: req.Ref,
		Message: fmt.Sprintf("ref=%d description=%q stock=%d price=%.2f -> available=%v",
			req.Ref, req.Description, req.Stock, req.Price, available),
	}
	out, err := json.Marshal(resp)
	if err != nil {
		logger.Error("encode response failed", "error", err)
		return jsonError(500, "internal server error"), nil
	}

	return events.APIGatewayV2HTTPResponse{
		StatusCode: 200,
		Headers:    map[string]string{"Content-Type": "application/json"},
		Body:       string(out),
	}, nil
}

// jsonError builds a JSON error response with the given status code and message.
func jsonError(status int, msg string) events.APIGatewayV2HTTPResponse {
	body, _ := json.Marshal(map[string]string{"error": msg})
	return events.APIGatewayV2HTTPResponse{
		StatusCode: status,
		Headers:    map[string]string{"Content-Type": "application/json"},
		Body:       string(body),
	}
}

func main() {
	logger = slog.New(slog.NewJSONHandler(os.Stderr, nil))
	apiKey = os.Getenv("LAMBDA_API_KEY")
	loadCatalog()
	lambda.Start(handle)
}

// loadCatalog reads the product-catalog reference shipped via the Lambda layer
// into the package-level catalog slice. It is non-fatal: a missing or
// unreadable file (e.g. layer not attached, wrong path) logs a warning and
// leaves catalog empty so the availability-echo endpoint keeps serving.
// CATALOG_PATH overrides the default /opt mount for local testing.
func loadCatalog() {
	p := os.Getenv("CATALOG_PATH")
	if p == "" {
		p = catalogPath
	}
	b, err := os.ReadFile(p)
	if err != nil {
		logger.Warn("catalog not loaded (layer missing or wrong path)",
			"path", p, "error", err)
		return
	}
	if err := json.Unmarshal(b, &catalog); err != nil {
		logger.Error("catalog parse failed", "path", p, "error", err)
		return
	}
	logger.Info("catalog loaded", "path", p, "count", len(catalog))
}

// serveCatalog builds the JSON response for GET /products from the loaded
// catalog slice. It returns an empty list (rather than null) when the layer was
// not loaded, so consumers always get an array-shaped body.
func serveCatalog() events.APIGatewayV2HTTPResponse {
	out := catalog
	if out == nil {
		out = []catalogProduct{}
	}
	b, err := json.Marshal(out)
	if err != nil {
		logger.Error("encode catalog failed", "error", err)
		return jsonError(500, "internal server error")
	}
	return events.APIGatewayV2HTTPResponse{
		StatusCode: 200,
		Headers:    map[string]string{"Content-Type": "application/json"},
		Body:       string(b),
	}
}
