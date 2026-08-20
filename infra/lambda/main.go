// Package main is the custom-runtime AWS Lambda handler for api-command.
//
// It targets the "provided.al2023" custom runtime: the Go program is compiled
// to a binary named "bootstrap" (GOOS=linux, GOARCH=arm64), zipped, and
// deployed as the Lambda code. aws-lambda-go drives the Lambda Runtime API.
package main

import (
	"context"
	"fmt"

	"github.com/aws/aws-lambda-go/lambda"
)

// Request is the event payload accepted by the handler.
type Request struct {
	Ref         int     `json:"ref,omitempty"`
	Description string  `json:"description,omitempty"`
	Stock       int     `json:"stock,omitempty"`
	Price       float64 `json:"price,omitempty"`
}

// Response is returned to the caller.
type Response struct {
	OK      bool   `json:"ok"`
	Ref     int    `json:"ref"`
	Message string `json:"message"`
}

// handle processes a single invocation.
func handle(ctx context.Context, req Request) (Response, error) {
	available := req.Stock > 0
	return Response{
		OK:      available,
		Ref:     req.Ref,
		Message: fmt.Sprintf("ref=%d description=%q stock=%d price=%.2f -> available=%v",
			req.Ref, req.Description, req.Stock, req.Price, available),
	}, nil
}

func main() {
	lambda.Start(handle)
}
