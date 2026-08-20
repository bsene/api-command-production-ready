// Package main is the custom-runtime AWS Lambda handler for api-command.
//
// It targets the "provided.al2023" custom runtime: the Go program is compiled
// to a binary named "bootstrap" (GOOS=linux, GOARCH=arm64), zipped, and
// deployed as the Lambda code. aws-lambda-go drives the Lambda Runtime API.
//
// The handler is wired to a Lambda Function URL, which delivers the request as
// an API Gateway v2 (HTTP API) payload-format-2.0 event — the raw HTTP body
// lives in event.Body, not in the top-level event.
package main

import (
	"context"
	"encoding/json"
	"fmt"

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

// handle processes a single Function URL invocation.
func handle(ctx context.Context, event events.APIGatewayV2HTTPRequest) (string, error) {
	var req Request
	if err := json.Unmarshal([]byte(event.Body), &req); err != nil {
		return "", fmt.Errorf("decode body: %w", err)
	}
	available := req.Stock > 0
	resp := Response{
		OK:      available,
		Ref:     req.Ref,
		Message: fmt.Sprintf("ref=%d description=%q stock=%d price=%.2f -> available=%v",
			req.Ref, req.Description, req.Stock, req.Price, available),
	}
	out, err := json.Marshal(resp)
	if err != nil {
		return "", fmt.Errorf("encode response: %w", err)
	}
	return string(out), nil
}

func main() {
	lambda.Start(handle)
}
