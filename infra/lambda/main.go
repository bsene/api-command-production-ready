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
	"encoding/json"
	"fmt"
	"log/slog"
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

// logger is initialized in main() so tests can inspect log output via the
// default handler if needed.
var logger *slog.Logger

// apiKey is the expected API key, read once from LAMBDA_API_KEY at startup.
var apiKey string

// handle processes a single Function URL invocation.
//
// It first authenticates the request via the x-api-key header, then
// deserializes the JSON body and returns the availability result.
func handle(ctx context.Context, event events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
	// --- Authentication (A01) ----------------------------------------------

	// Reject if no API key was configured at deploy time. This is a
	// deployment misconfiguration, not a caller error — log it and return 500
	// so the operator notices immediately rather than silently allowing all
	// traffic through.
	if apiKey == "" {
		logger.Error("LAMBDA_API_KEY not set — refusing to serve without authentication")
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

	// --- Business logic ----------------------------------------------------

	// Guard: a GET request or a bodyless POST delivers an empty event.Body.
	// json.Unmarshal("") returns "unexpected end of JSON input", which is a
	// confusing 400 message. Return a clearer error so the caller knows they
	// must send a JSON body.
	if strings.TrimSpace(event.Body) == "" {
		return jsonError(400, "missing request body"), nil
	}

	var req Request
	if err := json.Unmarshal([]byte(event.Body), &req); err != nil {
		return jsonError(400, "invalid request body"), nil
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
	lambda.Start(handle)
}
