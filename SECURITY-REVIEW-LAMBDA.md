# Security Review — Lambda Function (api-command)

**Date:** 2026-08-20
**Scope:** Lambda handler in `infra/lambda/` and its Pulumi wiring in `infra/src/index.ts`. Report only — no code changes applied.
**Runtime:** Go `provided.al2023` handler behind a public Lambda Function URL. AWS does not enforce auth (`authorizationType: "NONE"`); the handler authenticates each request itself via the `x-api-key` header compared constant-time against `LAMBDA_API_KEY` (injected as a Pulumi secret).

## What is already done well

- Constant-time key comparison (`crypto/subtle.ConstantTimeCompare`) — no timing side-channel on the secret. `infra/lambda/main.go:72`.
- Fail-closed: empty configured key returns 500, never open. `infra/lambda/main.go:66-69`.
- Auth gate runs before business logic / body parse. `infra/lambda/main.go:66-78`.
- Unauthorized log line does NOT log the provided key — no secret leakage to logs. `infra/lambda/main.go:73-76`.
- API key stored as a Pulumi secret (`requireSecret`), encrypted in state, never in source. `infra/src/index.ts:39`.
- IAM role is least-privilege: `AWSLambdaBasicExecutionRole` only (CloudWatch Logs), no broad data-plane access. `infra/src/index.ts:64-71`.
- JSON error responses use generic messages; no stack traces returned to caller.

## Findings

### MEDIUM — M1: No rate limiting / throttling on public endpoint — **Resolved (residual risk accepted)**
The Function URL is public (`principal: "*"`, `authorizationType: "NONE"`) with no WAF, CloudFront, or per-caller throttling in front. `infra/src/index.ts:117-160`. Anyone can hammer the endpoint; the only gate is the app-level key check.

Consequences:
- (a) brute-force attack on `LAMBDA_API_KEY` if the operator chose a weak/short key — no lockout or backoff;
- (b) cost/billing DoS via sustained invocations;
- (c) Lambda concurrency exhaustion starving legitimate traffic.

**Mitigations in place (commit e83c9d8):**
- Strong key enforced at deploy time (`infra/src/index.ts:40-47`) and fail-closed at handler startup (`infra/lambda/main.go:87-91`): a key shorter than 32 bytes (256-bit) fails `pulumi preview`/`up`, and the handler refuses to serve.
- Reserved concurrency capped at 5 by default (`infra/src/index.ts:53,134`), bounding cost-DoS and preventing concurrency exhaustion.

**Accepted residual risk:**
- No WAF/CloudFront edge throttle and no per-IP brute-force lockout/backoff. Accepted for the prototype because a 256-bit key makes brute-force computationally infeasible and reserved concurrency caps cost-DoS. CloudFront + WAF rate-based rules remain the deferred full-edge option.

### MEDIUM — M2: `lambda:InvokeFunction` granted to `principal: "*"` (over-broad)
`infra/src/index.ts:152-160` grants plain `lambda:InvokeFunction` to `*` to satisfy the Oct-2025 AWS requirement for unauthenticated Function URL invocations (Pulumi v6 lacks `invokedViaFunctionUrl`). This is broader than `InvokeFunctionUrl` — it permits invocation via any path (SDK, API Gateway, other triggers), not just the URL.

Defense in depth rests entirely on the handler-level key check: if that check were ever bypassed or removed, the function is open to the world. Recommendation: revisit when Pulumi exposes `invokedViaFunctionUrl` (or scope the grant via a `functionUrlAuthType` condition on the `InvokeFunction` statement) to limit to URL-sourced calls. Until then, keep the handler auth gate as the single choke point and add a regression test that fails if the key check is removed.

### LOW — L1: API key held in Lambda env var (no rotation, retrievable by privileged callers)
`LAMBDA_API_KEY` is injected as a Lambda environment variable. `infra/src/index.ts:94-98`. AWS encrypts env vars at rest, but they are plaintext inside the execution environment and retrievable by any principal with `lambda:GetFunctionConfiguration` or the ability to exfil from the runtime. There is no rotation story: rotating the key requires a Pulumi config update + redeploy.

Recommendation for higher-sensitivity deployments: pull the key from AWS Secrets Manager / SSM Parameter Store at cold-start (cached in the global) so rotation does not require a code redeploy and access can be audited. For current sensitivity (prototype), env var is acceptable but should be noted.

### LOW — L2: Unbounded / unvalidated request body fields
`Request` (`infra/lambda/main.go:34-39`) accepts arbitrary `Description` (no length cap), `Stock`, `Price`, `Ref` with no validation. `Description` is echoed back into `Message` via `fmt.Sprintf` (`main.go:91-92`).

Impacts:
- (a) memory amplification — a huge `description` is stored in the response body;
- (b) negative/zero `price` accepted silently and reflected.

No XSS risk because the response is `application/json` (browsers do not execute it) and `json.Marshal` escapes correctly. Recommendation: cap `Description` length (e.g. reject >1KB) and validate `Price >= 0` and `Ref >= 0` before processing; return 400 on violation.

### LOW — L3: No handling of base64-encoded bodies
`event.Body` is used directly with `json.Unmarshal` (`infra/lambda/main.go:83`) without checking `event.IsBase64Encoded`. If a client (or a future proxy) sends a base64-encoded body, parsing fails with a 400 — not a security hole, but a correctness gap that could mask a real issue. Recommendation: decode base64 when `IsBase64Encoded` is true before unmarshalling.

### INFO — I1: Logs reflect untrusted `event.RawPath`
The unauthorized-request log includes `event.RawPath` and `method` (`main.go:74-75`). `slog`'s JSON handler escapes values, so log injection is contained, but raw path is attacker-controlled and will appear in CloudWatch. Acceptable; noting for completeness.

### INFO — I2: `jsonError` discards marshal error
`infra/lambda/main.go:109` ignores the error from `json.Marshal` of a `map[string]string` (which cannot fail in practice). Harmless; noting only.

## Severity summary

| ID | Severity | Area | One-line |
|----|----------|------|----------|
| M1 | Medium | infra | Resolved: strong key + reserved concurrency; edge throttle/lockout accepted as residual risk |
| M2 | Medium | infra | `InvokeFunction` to `*` is broader than URL-only; handler key check is sole defense |
| L1 | Low | infra | Key in env var, no rotation path, retrievable by privileged callers |
| L2 | Low | handler | Unbounded/unvalidated body fields (description, price, ref) |
| L3 | Low | handler | Base64-encoded bodies not decoded (correctness gap) |
| I1 | Info | handler | Untrusted RawPath written to logs (escaped by slog) |
| I2 | Info | handler | `jsonError` ignores marshal error (cannot fail) |

## Verification (no changes made)

No code was modified. To confirm the review reflects current code:
- The Lambda handler test suite was removed (commit 6a93490), so `cd infra/lambda && go test ./...` runs no tests; the handler has no in-tree tests at present.
- Re-read `infra/lambda/main.go:59-105` (handler + auth) and `infra/src/index.ts:39-160` (secret, IAM, Function URL, permissions).

## Next steps (if you choose to act later)

Priority order if fixes are requested:
1. M2 — scope the `*` `InvokeFunction` grant to URL-sourced calls.
2. L2 — input validation (description length, price/ref sign).
3. L1 — Secrets Manager / SSM rotation path.
4. L3 — base64 decode.