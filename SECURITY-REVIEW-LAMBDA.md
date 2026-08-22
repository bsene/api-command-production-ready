# Security Review — Lambda Function (api-command)

**Date:** 2026-08-20 (updated for the OCaml port, commit `d8386e4`+)
**Scope:** Lambda handler in `lambda/` (OCaml, `lambda_handler.ml`) and its Pulumi wiring in `infra/src/index.ts`. Report only — no code changes applied.
**Runtime:** OCaml `provided.al2023` handler (hand-rolled Runtime API loop in `lambda/runtime.ml`) behind a public Lambda Function URL. AWS does not enforce auth (`authorizationType: "NONE"`); the handler authenticates each request itself via the `x-api-key` header compared constant-time against `LAMBDA_API_KEY` (injected as a Pulumi secret).

## What is already done well

- Constant-time key comparison (`Constant_time.equal`) — no timing side-channel on the secret. `lambda/lambda_handler.ml:128`.
- Fail-closed: key shorter than 32 bytes returns 500, never open. `lambda/lambda_handler.ml:120-125`.
- Auth gate runs before business logic / body parse. `lambda/lambda_handler.ml:128-152`.
- Unauthorized log line does NOT log the provided key — no secret leakage to logs. `lambda/lambda_handler.ml:129-131`.
- API key stored as a Pulumi secret (`requireSecret`), encrypted in state, never in source. `infra/src/index.ts:40`.
- IAM role is least-privilege: `AWSLambdaBasicExecutionRole` only (CloudWatch Logs), no broad data-plane access. `infra/src/index.ts:82`.
- Handler-level global rate limiter counts only failed-authentication traffic (missing or wrong `x-api-key`), throttling floods after the key comparison. Authenticated traffic is exempt. `lambda/lambda_handler.ml:102-170`, `lambda/rate_limit.ml`.
- JSON error responses use generic messages; no stack traces returned to caller.

## Findings

### MEDIUM — M1: No rate limiting / throttling on public endpoint — **Resolved (residual risk accepted)**
The Function URL is public (`principal: "*"`, `authorizationType: "NONE"`) with no WAF, CloudFront, or per-caller throttling in front. `infra/src/index.ts:117-160`. Anyone can hammer the endpoint; the only gate is the app-level key check.

Consequences:
- (a) brute-force attack on `LAMBDA_API_KEY` if the operator chose a weak/short key — no lockout or backoff;
- (b) cost/billing DoS via sustained invocations;
- (c) Lambda concurrency exhaustion starving legitimate traffic.

**Mitigations in place (commit e83c9d8, rate limiter added in the A05 work):**
- Strong key enforced at deploy time (`infra/src/index.ts:40-43`) and fail-closed at handler startup (`lambda/lambda_handler.ml:113-117`): a key shorter than 32 bytes (256-bit) fails `pulumi preview`/`up`, and the handler refuses to serve.
- Reserved concurrency capped at 5 by default (`infra/src/index.ts:53,135`), bounding cost-DoS and preventing concurrency exhaustion.
- Handler-level global fixed-window rate limiter (`lambda/rate_limit.ml`, 120 req/60s), checked only on failed authentication (`lambda/lambda_handler.ml:149-166`). Missing or wrong `x-api-key` traffic counts toward the shared bucket; authenticated traffic is exempt. Over-limit calls get `429` + `Retry-After`. The caller IP is decoded from `requestContext.http.sourceIp` and logged as `source_ip` (label only, not a bucket key).

**Accepted residual risk:**
- No WAF/CloudFront edge throttle. Accepted for the prototype because reserved concurrency caps cost-DoS and the handler-level global limiter now bounds unauth-only floods. CloudFront + WAF rate-based rules remain the deferred full-edge option.
- The handler-level limiter is best-effort: its bucket is per execution environment, so it resets on cold start and is *not* shared across parallel Lambda instances (under horizontal scale an attacker can exceed the per-instance cap across instances). It is a backstop, not a hard edge limit.

### MEDIUM — M2: `lambda:InvokeFunction` granted to `principal: "*"` (over-broad)
`infra/src/index.ts:201-203` grants plain `lambda:InvokeFunction` to `*` to satisfy the Oct-2025 AWS requirement for unauthenticated Function URL invocations (Pulumi v6 lacks `invokedViaFunctionUrl`). This is broader than `InvokeFunctionUrl` — it permits invocation via any path (SDK, API Gateway, other triggers), not just the URL.

Defense in depth rests entirely on the handler-level key check: if that check were ever bypassed or removed, the function is open to the world. Recommendation: revisit when Pulumi exposes `invokedViaFunctionUrl` (or scope the grant via a `functionUrlAuthType` condition on the `InvokeFunction` statement) to limit to URL-sourced calls. Until then, keep the handler auth gate as the single choke point and add a regression test that fails if the key check is removed.

### LOW — L1: API key held in Lambda env var (no rotation, retrievable by privileged callers)
`LAMBDA_API_KEY` is injected as a Lambda environment variable. `infra/src/index.ts:139-141`. AWS encrypts env vars at rest, but they are plaintext inside the execution environment and retrievable by any principal with `lambda:GetFunctionConfiguration` or the ability to exfil from the runtime. There is no rotation story: rotating the key requires a Pulumi config update + redeploy.

Recommendation for higher-sensitivity deployments: pull the key from AWS Secrets Manager / SSM Parameter Store at cold-start (cached in the global) so rotation does not require a code redeploy and access can be audited. For current sensitivity (prototype), env var is acceptable but should be noted.

### LOW — L2: Request body field validation — **Resolved by the OCaml port**
The Go handler accepted arbitrary `Description` (no length cap) and unvalidated `Stock`/`Price`/`Ref`. The OCaml port validates at `lambda/lambda_handler.ml:143-148`: `description` > 1 KiB → 400, `price < 0` → 400, `ref < 0` → 400, and `Message` quotes `description` via `go_quote` (`lambda/lambda_handler.ml:31-60`) so the JSON response stays well-formed. Residual: `stock` sign is still not validated separately (only used as `> 0` for availability).

### LOW — L3: Base64-encoded bodies — **Resolved by the OCaml port**
The Go handler used `event.Body` directly with `json.Unmarshal`, ignoring `IsBase64Encoded`. The OCaml port decodes base64 first when `is_base64_encoded` is set (`decode_body`, `lambda/lambda_handler.ml:77-92`), returning 400 only on invalid base64 — closing the correctness gap.

### INFO — I1: Logs reflect untrusted `raw_path` — **Resolved**
The unauthorized-request log includes `raw_path` and `method` (`lambda/lambda_handler.ml:129-130`). The `Log` module (`lib/log.ml`) did NOT escape values — unlike Go's `slog` JSON handler — so a crafted path could inject log fields. Attacker-controlled path would appear in CloudWatch.

**Fix (in-tree, commits `a3a7f89` + `e715b51`):** `lib/log.ml` now conditionally quotes+escapes string values containing injection characters (space, `=`, `"`, `\`, control chars) via `escape_string`/`needs_quoting`, so a crafted `raw_path` cannot inject a fake `level=`/`msg=` field. Clean values (URLs, hostnames, refs) stay bare to preserve the slog text-handler format. Regression covered by `injection_test` in `lib/test/log_test.ml`.

### INFO — I2: `json_error` builds the body with `Yojson.Safe.to_string`
`lambda/event.ml:75` builds the error body with `Yojson.Safe.to_string`, which returns a `string` directly (there is no error channel to discard), so nothing is silently swallowed. Harmless; noting only.

## Severity summary

| ID | Severity | Area | One-line |
|----|----------|------|----------|
| M1 | Medium | infra | Resolved: strong key + reserved concurrency + handler global unauth-only rate limiter; WAF/CloudFront edge throttle accepted as residual risk |
| M2 | Medium | infra | `InvokeFunction` to `*` is broader than URL-only; handler key check is sole defense |
| L1 | Low | infra | Key in env var, no rotation path, retrievable by privileged callers |
| L2 | Low | handler | Resolved by OCaml port: description ≤1 KiB, price/ref ≥ 0 (400 on violation) |
| L3 | Low | handler | Resolved by OCaml port: base64 bodies decoded before parsing |
| I1 | Info | handler | Resolved: Log module escapes string values; crafted raw_path cannot inject log fields |
| I2 | Info | handler | `json_error` ignores marshal error (cannot fail) |

## Verification (no changes made)

No code was modified by this review. To confirm the review reflects current code:
- The Lambda handler has **no in-tree unit tests** (`lambda/test/` was removed). Black-box validation lives in `smoke-tests/prod/*.hurl` — including `lambda-rate-limited.hurl` (the per-IP lockout) — run via `task smoke:prod`, the post-deploy gate. The DoS guard is additionally exercised by `task load:throttle` (vegeta, expects 429).
- Re-read `lambda/lambda_handler.ml:102-170` (handler + auth + rate limit), `lambda/rate_limit.ml`, `lambda/event.ml`, and `infra/src/index.ts:40-203` (secret, IAM, Function URL, permissions).

## Next steps (if you choose to act later)

Priority order if fixes are requested:
1. M2 — scope the `*` `InvokeFunction` grant to URL-sourced calls.
2. L1 — Secrets Manager / SSM rotation path.

(I1 — escape values in the `Log` module — is now **Resolved**.)