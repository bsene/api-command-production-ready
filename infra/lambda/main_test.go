package main

import (
	"encoding/json"
	"log/slog"
	"os"
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

func TestHandle_MissingAPIKeyHeader(t *testing.T) {
	setAPIKey(t, "secret-key")
	event := events.APIGatewayV2HTTPRequest{
		Body:    `{"ref":1,"stock":5}`,
		Headers: map[string]string{}, // no x-api-key
	}

	resp, err := handle(t.Context(), event)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.StatusCode != 401 {
		t.Fatalf("expected status 401, got %d", resp.StatusCode)
	}
}

func TestHandle_WrongAPIKeyHeader(t *testing.T) {
	setAPIKey(t, "secret-key")
	event := events.APIGatewayV2HTTPRequest{
		Body:    `{"ref":1,"stock":5}`,
		Headers: map[string]string{"x-api-key": "wrong-key"},
	}

	resp, err := handle(t.Context(), event)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.StatusCode != 401 {
		t.Fatalf("expected status 401, got %d", resp.StatusCode)
	}
}

func TestHandle_NoAPIKeyConfigured(t *testing.T) {
	setAPIKey(t, "") // simulates deployment without LAMBDA_API_KEY
	event := events.APIGatewayV2HTTPRequest{
		Body:    `{"ref":1,"stock":5}`,
		Headers: map[string]string{"x-api-key": "anything"},
	}

	resp, err := handle(t.Context(), event)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.StatusCode != 500 {
		t.Fatalf("expected status 500 (misconfigured), got %d", resp.StatusCode)
	}
}

func TestHandle_ValidAPIKey_HappyPath(t *testing.T) {
	setAPIKey(t, "secret-key")
	event := events.APIGatewayV2HTTPRequest{
		Body:    `{"ref":1,"description":"vélo","stock":5,"price":100}`,
		Headers: map[string]string{"x-api-key": "secret-key"},
	}

	resp, err := handle(t.Context(), event)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.StatusCode != 200 {
		t.Fatalf("expected status 200, got %d (body: %s)", resp.StatusCode, resp.Body)
	}

	var result Response
	if err := json.Unmarshal([]byte(resp.Body), &result); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if !result.OK {
		t.Errorf("expected OK=true for stock>0, got false")
	}
	if result.Ref != 1 {
		t.Errorf("expected Ref=1, got %d", result.Ref)
	}
}

func TestHandle_ValidAPIKey_StockZero(t *testing.T) {
	setAPIKey(t, "secret-key")
	event := events.APIGatewayV2HTTPRequest{
		Body:    `{"ref":3,"description":"raquette","stock":0,"price":80}`,
		Headers: map[string]string{"x-api-key": "secret-key"},
	}

	resp, err := handle(t.Context(), event)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.StatusCode != 200 {
		t.Fatalf("expected status 200, got %d", resp.StatusCode)
	}

	var result Response
	if err := json.Unmarshal([]byte(resp.Body), &result); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if result.OK {
		t.Errorf("expected OK=false for stock=0, got true")
	}
}

func TestHandle_InvalidJSON(t *testing.T) {
	setAPIKey(t, "secret-key")
	event := events.APIGatewayV2HTTPRequest{
		Body:    `{not valid json}`,
		Headers: map[string]string{"x-api-key": "secret-key"},
	}

	resp, err := handle(t.Context(), event)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.StatusCode != 400 {
		t.Fatalf("expected status 400, got %d", resp.StatusCode)
	}
}

func TestMain(m *testing.M) {
	// Ensure logger is initialized for test runs.
	logger = slog.New(slog.NewJSONHandler(os.Stderr, nil))
	os.Exit(m.Run())
}
