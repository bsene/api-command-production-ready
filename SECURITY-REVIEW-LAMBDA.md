# Security Review — Lambda Function (api-command)

**Date:** 2026-08-20 (updated for the OCaml port, commit `d8386e4`+)
**Scope:** Lambda handler in `lambda/` (OCaml, `lambda_handler.ml`) and its Pulumi wiring in `infra/src/index.ts`. Report only — no code changes applied.
**Runtime:** OCaml `provided.al2023` handler (hand-rolled Runtime API loop in `lambda/runtime.ml`) behind a public Lambda Function URL. AWS does not enforce auth (`authorizationType: "NONE"`); the handler authenticates each request itself via the `x-api-key` header compared constant-time against `LAMBDA_API_KEY` (injected as a Pulumi secret).

## What is already done well

- Constant-time key comparison (`Constant_time.equal`) — no timing side-channel on the secret. `lambda/lambda_handler.ml:110`.
- Fail-closed: key shorter than 32 bytes returns 500, never open. `lambda/lambda_handler.ml:102-106`.
- Auth gate runs before business logic / body parse. `lambda/lambda_handler.ml:109-130`.
- Unauthorized log line does NOT log the provided key — no secret leakage to logs. `lambda/lambda_handler.ml:111-113`.
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
- Strong key enforced at deploy time (`infra/src/index.ts:40-47`) and fail-closed at handler startup (`lambda/lambda_handler.ml:102-106`): a key shorter than 32 bytes (256-bit) fails `pulumi preview`/`up`, and the handler refuses to serve.
- Reserved concurrency capped at 5 by default (`infra/src/index.ts:53,134`), bounding cost-DoS and preventing concurrency exhaustion.

**Accepted residual risk:**
- No WAF/CloudFront edge throttle and no per-IP brute-force lockout/backoff. Accepted for the prototype because a 256-bit key makes brute-force computationally infeasible and reserved concurrency caps cost-DoS. CloudFront + WAF rate-based rules remain the deferred full-edge option.

### MEDIUM — M2: `lambda:InvokeFunction` granted to `principal: "*"` (over-broad)
`infra/src/index.ts:152-160` grants plain `lambda:InvokeFunction` to `*` to satisfy the Oct-2025 AWS requirement for unauthenticated Function URL invocations (Pulumi v6 lacks `invokedViaFunctionUrl`). This is broader than `InvokeFunctionUrl` — it permits invocation via any path (SDK, API Gateway, other triggers), not just the URL.

Defense in depth rests entirely on the handler-level key check: if that check were ever bypassed or removed, the function is open to the world. Recommendation: revisit when Pulumi exposes `invokedViaFunctionUrl` (or scope the grant via a `functionUrlAuthType` condition on the `InvokeFunction` statement) to limit to URL-sourced calls. Until then, keep the handler auth gate as the single choke point and add a regression test that fails if the key check is removed.

### LOW — L1: API key held in Lambda env var (no rotation, retrievable by privileged callers)
`LAMBDA_API_KEY` is injected as a Lambda environment variable. `infra/src/index.ts:94-98`. AWS encrypts env vars at rest, but they are plaintext inside the execution environment and retrievable by any principal with `lambda:GetFunctionConfiguration` or the ability to exfil from the runtime. There is no rotation story: rotating the key requires a Pulumi config update + redeploy.

Recommendation for higher-sensitivity deployments: pull the key from AWS Secrets Manager / SSM Parameter Store at cold-start (cached in the global) so rotation does not require a code redeploy and access can be audited. For current sensitivity (prototype), env var is acceptable but should be noted.

### LOW — L2: Request body field validation — **Resolved by the OCaml port**
The Go handler accepted arbitrary `Description` (no length cap) and unvalidated `Stock`/`Price`/`Ref`. The OCaml port validates at `lambda/lambda_handler.ml:125-130`: `description` > 1 KiB → 400, `price < 0` → 400, `ref < 0` → 400, and `Message` quotes `description` via `go_quote` (`lambda/lambda_handler.ml:33-62`) so the JSON response stays well-formed. Residual: `stock` sign is still not validated separately (only used as `> 0` for availability).

### LOW — L3: Base64-encoded bodies — **Resolved by the OCaml port**
The Go handler used `event.Body` directly with `json.Unmarshal`, ignoring `IsBase64Encoded`. The OCaml port decodes base64 first when `is_base64_encoded` is set (`decode_body`, `lambda/lambda_handler.ml:75-83`), returning 400 only on invalid base64 — closing the correctness gap.

### INFO — I1: Logs reflect untrusted `raw_path` — **Resolved**
The unauthorized-request log includes `raw_path` and `method` (`lambda/lambda_handler.ml:111-112`). The `Log` module (`lib/log.ml`) did NOT escape values — unlike Go's `slog` JSON handler — so a crafted path could inject log fields. Attacker-controlled path would appear in CloudWatch.

**Fix (commit pending):** `lib/log.ml` now conditionally quotes+escapes string values containing injection characters (space, `=`, `"`, `\`, control chars) via `escape_string`/`needs_quoting`, so a crafted `raw_path` cannot inject a fake `level=`/`msg=` field. Clean values (URLs, hostnames, refs) stay bare to preserve the slog text-handler format. Regression covered by `injection_test` in `lib/test/log_test.ml`.

### INFO — I2: `json_error` discards marshal error
`lambda/event.ml:62-66` ignores the error from `Yojson.Safe.to_string` of a fixed record (which cannot fail in practice). Harmless; noting only.

## Severity summary

| ID | Severity | Area | One-line |
|----|----------|------|----------|
| M1 | Medium | infra | Resolved: strong key + reserved concurrency; edge throttle/lockout accepted as residual risk |
| M2 | Medium | infra | `InvokeFunction` to `*` is broader than URL-only; handler key check is sole defense |
| L1 | Low | infra | Key in env var, no rotation path, retrievable by privileged callers |
| L2 | Low | handler | Resolved by OCaml port: description ≤1 KiB, price/ref ≥ 0 (400 on violation) |
| L3 | Low | handler | Resolved by OCaml port: base64 bodies decoded before parsing |
| I1 | Info | handler | Resolved: Log module escapes string values; crafted raw_path cannot inject log fields |
| I2 | Info | handler | `json_error` ignores marshal error (cannot fail) |

## Verification (no changes made)

No code was modified by this review. To confirm the review reflects current code:
- The OCaml handler has in-tree tests: `lambda/test/lambda_test.ml` and `lambda/test/loop_test.ml`, run via `dune runtest` (no Go test suite exists — the Go handler was removed in the OCaml migration).
- Re-read `lambda/lambda_handler.ml:97-136` (handler + auth) and `infra/src/index.ts:39-160` (secret, IAM, Function URL, permissions).

## Next steps (if you choose to act later)

Priority order if fixes are requested:
1. M2 — scope the `*` `InvokeFunction` grant to URL-sourced calls.
2. L1 — Secrets Manager / SSM rotation path.

(I1 — escape values in the `Log` module — is now **Resolved**.)