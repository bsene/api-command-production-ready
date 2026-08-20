package main

import (
	"encoding/base64"
	"encoding/json"
	"log/slog"
	"os"
	"strings"
	"testing"

	"github.com/aws/aws-lambda-go/events"
)

// setAPIKey sets the package-level apiKey for the duration of the test and
// restores the original value on cleanup.
func setAPIKey(t *testing.T, key string) {
	t.Helper()
	orig := apiKey
	apiKey = key
	t.Cleanup(func() { apiKey = orig })
}

func handleRequest(t *testing.T, ev events.APIGatewayV2HTTPRequest) events.APIGatewayV2HTTPResponse {
	t.Helper()
	resp, err := handle(t.Context(), ev)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	return resp
}

func validEvent(body string, headers map[string]string) events.APIGatewayV2HTTPRequest {
	return events.APIGatewayV2HTTPRequest{
		Body:    body,
		Headers: headers,
		RequestContext: events.APIGatewayV2HTTPRequestContext{
			HTTP: events.APIGatewayV2HTTPRequestContextHTTPDescription{Method: "POST"},
		},
	}
}

// --- A01: auth gate regression tests (M2) -----------------------------------

// The Function URL grants lambda:InvokeFunction to "*" (Oct-2025 AWS
// requirement; Pulumi v6 lacks invokedViaFunctionUrl), so the handler-level
// x-api-key check is the ONLY defense in depth. These tests fail if that
// check is removed or bypassed — the regression guard recommended by the
// security review (SECURITY-REVIEW-LAMBDA.md, M2).

func TestHandle_AuthGate_RejectsMissingKey(t *testing.T) {
	setAPIKey(t, "0123456789abcdef0123456789abcdef")
	event := validEvent(`{"ref":1,"stock":5}`, map[string]string{})
	resp := handleRequest(t, event)
	if resp.StatusCode != 401 {
		t.Fatalf("auth gate bypassed: expected 401 for missing key, got %d (body: %s)", resp.StatusCode, resp.Body)
	}
}

func TestHandle_AuthGate_RejectsWrongKey(t *testing.T) {
	setAPIKey(t, "0123456789abcdef0123456789abcdef")
	event := validEvent(`{"ref":1,"stock":5}`, map[string]string{"x-api-key": "wrong-key"})
	resp := handleRequest(t, event)
	if resp.StatusCode != 401 {
		t.Fatalf("auth gate bypassed: expected 401 for wrong key, got %d (body: %s)", resp.StatusCode, resp.Body)
	}
}

func TestHandle_AuthGate_RejectsEmptyConfiguredKey(t *testing.T) {
	setAPIKey(t, "") // deployment without LAMBDA_API_KEY
	event := validEvent(`{"ref":1,"stock":5}`, map[string]string{"x-api-key": "0123456789abcdef0123456789abcdef"})
	resp := handleRequest(t, event)
	if resp.StatusCode != 500 {
		t.Fatalf("expected 500 when no key is configured, got %d (body: %s)", resp.StatusCode, resp.Body)
	}
}

func TestHandle_AuthGate_AdmitsMatchingKey(t *testing.T) {
	const key = "0123456789abcdef0123456789abcdef"
	setAPIKey(t, key)
	event := validEvent(`{"ref":1,"stock":5}`, map[string]string{"x-api-key": key})
	resp := handleRequest(t, event)
	if resp.StatusCode != 200 {
		t.Fatalf("expected 200 for matching key, got %d (body: %s)", resp.StatusCode, resp.Body)
	}
}

// --- Body handling: base64 decode (L3) and field validation (L2) ------------

func TestHandle_Base64EncodedBodyIsDecoded(t *testing.T) {
	setAPIKey(t, "0123456789abcdef0123456789abcdef")
	raw := `{"ref":1,"description":"vélo","stock":5,"price":100}`
	event := validEvent(base64.StdEncoding.EncodeToString([]byte(raw)), map[string]string{"x-api-key": "0123456789abcdef0123456789abcdef"})
	event.IsBase64Encoded = true
	resp := handleRequest(t, event)
	if resp.StatusCode != 200 {
		t.Fatalf("expected 200 for base64 body, got %d (body: %s)", resp.StatusCode, resp.Body)
	}
	if !strings.Contains(resp.Body, `"ok":true`) {
		t.Fatalf("expected ok=true in decoded response, got %s", resp.Body)
	}
}

func TestHandle_InvalidBase64BodyIsRejected(t *testing.T) {
	setAPIKey(t, "0123456789abcdef0123456789abcdef")
	event := validEvent("not-base64!!", map[string]string{"x-api-key": "0123456789abcdef0123456789abcdef"})
	event.IsBase64Encoded = true
	resp := handleRequest(t, event)
	if resp.StatusCode != 400 {
		t.Fatalf("expected 400 for invalid base64, got %d (body: %s)", resp.StatusCode, resp.Body)
	}
}

func TestHandle_RejectsNegativePrice(t *testing.T) {
	setAPIKey(t, "0123456789abcdef0123456789abcdef")
	event := validEvent(`{"ref":1,"stock":5,"price":-1}`, map[string]string{"x-api-key": "0123456789abcdef0123456789abcdef"})
	resp := handleRequest(t, event)
	if resp.StatusCode != 400 {
		t.Fatalf("expected 400 for negative price, got %d (body: %s)", resp.StatusCode, resp.Body)
	}
}

func TestHandle_RejectsNegativeRef(t *testing.T) {
	setAPIKey(t, "0123456789abcdef0123456789abcdef")
	event := validEvent(`{"ref":-1,"stock":5}`, map[string]string{"x-api-key": "0123456789abcdef0123456789abcdef"})
	resp := handleRequest(t, event)
	if resp.StatusCode != 400 {
		t.Fatalf("expected 400 for negative ref, got %d (body: %s)", resp.StatusCode, resp.Body)
	}
}

func TestHandle_RejectsOversizeDescription(t *testing.T) {
	setAPIKey(t, "0123456789abcdef0123456789abcdef")
	big := strings.Repeat("x", 1025)
	event := validEvent(`{"ref":1,"description":"`+big+`","stock":5}`, map[string]string{"x-api-key": "0123456789abcdef0123456789abcdef"})
	resp := handleRequest(t, event)
	if resp.StatusCode != 400 {
		t.Fatalf("expected 400 for oversize description, got %d (body: %s)", resp.StatusCode, resp.Body)
	}
}

func TestHandle_AllowsZeroPriceAndRef(t *testing.T) {
	setAPIKey(t, "0123456789abcdef0123456789abcdef")
	event := validEvent(`{"ref":0,"stock":5,"price":0}`, map[string]string{"x-api-key": "0123456789abcdef0123456789abcdef"})
	resp := handleRequest(t, event)
	if resp.StatusCode != 200 {
		t.Fatalf("expected 200 for zero price/ref (only negatives rejected), got %d (body: %s)", resp.StatusCode, resp.Body)
	}
}

// --- GET /products catalog route --------------------------------------------

func TestHandle_GetProducts_ServesCatalog(t *testing.T) {
	setAPIKey(t, "0123456789abcdef0123456789abcdef")
	catalog = []catalogProduct{{Ref: 1, Description: "vélo", Stock: 10, Price: 1400}}
	t.Cleanup(func() { catalog = nil })
	event := events.APIGatewayV2HTTPRequest{
		Headers: map[string]string{"x-api-key": "0123456789abcdef0123456789abcdef"},
		RawPath: "/products",
		RequestContext: events.APIGatewayV2HTTPRequestContext{
			HTTP: events.APIGatewayV2HTTPRequestContextHTTPDescription{Method: "GET"},
		},
	}
	resp := handleRequest(t, event)
	if resp.StatusCode != 200 {
		t.Fatalf("expected 200 for GET /products, got %d (body: %s)", resp.StatusCode, resp.Body)
	}
	var got []catalogProduct
	if err := json.Unmarshal([]byte(resp.Body), &got); err != nil {
		t.Fatalf("decode catalog: %v", err)
	}
	if len(got) != 1 || got[0].Ref != 1 {
		t.Fatalf("expected 1 catalog entry, got %+v", got)
	}
}

func TestHandle_GetProducts_EmptyCatalogWhenLayerMissing(t *testing.T) {
	setAPIKey(t, "0123456789abcdef0123456789abcdef")
	catalog = nil
	event := events.APIGatewayV2HTTPRequest{
		Headers: map[string]string{"x-api-key": "0123456789abcdef0123456789abcdef"},
		RawPath: "/products",
		RequestContext: events.APIGatewayV2HTTPRequestContext{
			HTTP: events.APIGatewayV2HTTPRequestContextHTTPDescription{Method: "GET"},
		},
	}
	resp := handleRequest(t, event)
	if resp.StatusCode != 200 {
		t.Fatalf("expected 200 with empty list, got %d (body: %s)", resp.StatusCode, resp.Body)
	}
	if strings.TrimSpace(resp.Body) != "[]" {
		t.Fatalf("expected empty array, got %s", resp.Body)
	}
}

func TestMain(m *testing.M) {
	// Ensure logger is initialized for test runs.
	logger = slog.New(slog.NewJSONHandler(os.Stderr, nil))
	os.Exit(m.Run())
}
