# Dantotsu Analysis: Lambda handler accepted unbounded and unvalidated body fields

## Problem Statement

The Lambda handler (`infra/lambda/main.go`) accepted arbitrary `description`
(no length cap), negative `price`/`ref`, and failed to decode base64-encoded
bodies (`event.IsBase64Encoded` ignored). `description` is echoed into the
response via `fmt.Sprintf`, so an unbounded value amplifies memory; negative
domain quantities were silently accepted and reflected.

---

## Metadata

| Field                   | Value                                                      |
| ----------------------- | ---------------------------------------------------------- |
| 🟢 **ID**               | `OWASP-A04-LAMBDA-INPUT-VALIDATION`                        |
| 🟢 **Analysis Date**    | `2026/08/20`                                               |
| 🟢 **Project**          | `api-command-kata`                                         |
| 🟢 **Detection Stage**  | `B — Security audit (OWASP Top 10 review)`                |
| 🟢 **Startup**          | `bsene`                                                    |
| 🟢 **Status**           | `Fixed`                                                    |
| 🔵 **Weak point**       | `infra/lambda/main.go — handle()`                          |
| 🟢 **Owner**            | `birrame.sene`                                             |
| 🟢 **napta_project_id** | `api-command`                                              |
| **Standard**            | 🎓 Dantotsu                                                |

---

## User Impact

- **Memory amplification**: a caller can POST a multi-megabyte `description`;
  the handler stores it in the request struct and echoes it back into the
  response body, inflating memory and response size per invocation.
- **Invalid domain state**: negative `price`/`ref` are accepted and reflected
  in the response, so downstream consumers can receive nonsensical values
  (e.g. a negative price) that a real ordering system might trust.
- **Correctness gap**: base64-encoded bodies (which API Gateway v2 may
  deliver with `IsBase64Encoded: true`) fail to parse with a confusing 400,
  masking legitimate traffic.

---

## Causal Chain

1. `Request` is a plain struct with no validation; `handle()` unmarshals the
   body directly into it.
2. `description` is echoed into `Message` via `fmt.Sprintf` with no length
   bound — a huge value is stored and re-emitted.
3. `price` and `ref` are used in the response message with no sign check;
   negative values pass through and are reflected.
4. `event.Body` is passed straight to `json.Unmarshal` without consulting
   `event.IsBase64Encoded`, so encoded payloads 400.

---

## Root Cause of Occurrence

### The Misconception

"The Function URL delivers the raw JSON body; the caller is trusted to send
well-formed, bounded data. Validation belongs to the business layer, and this
handler is a thin echo endpoint."

### What Actually Happened

1. The endpoint is public (Function URL, `authorizationType: "NONE"`); the
   only gate is the API key, and any key holder (or a bypassed key check) can
   send arbitrary payloads.
2. Go's `json.Unmarshal` imposes no size or sign constraints — a 10 MB
   `description` or a negative `price` is accepted verbatim.
3. API Gateway v2 sets `IsBase64Encoded` for binary/encoded bodies; ignoring
   it turns legitimate requests into 400s.

### Contributing Factor

The handler was written as a minimal echo endpoint with no input contract.
The security review (SECURITY-REVIEW-LAMBDA.md, L2/L3) flagged all three
gaps; the fix landed in commit 7ce4ef2.

---

## Detection Failure Causes

### 1. Missing Tests

The handler test suite was removed in commit 6a93490, so no test exercised
oversize, negative, or base64-encoded bodies. The gaps were found by manual
review, not by a failing test.

### 2. Code Review

The echo path (`fmt.Sprintf` with `%q`/`%f`) looks harmless; the unbounded
`description` and unvalidated sign only become visible when considering
attacker-controlled input at scale.

---

## Countermeasure

### Changes Made (commit 7ce4ef2)

1. **Base64 decode (L3)**: when `event.IsBase64Encoded` is true, the body is
   decoded with `base64.StdEncoding` before unmarshalling; invalid base64
   returns 400.
2. **Description cap (L2)**: `description` longer than 1 KB is rejected with
   400 before processing.
3. **Sign validation (L2)**: negative `price` or `ref` is rejected with 400;
   zero remains allowed (only negatives are invalid).
4. **Regression tests (commit 32a1003)**: `TestHandle_Base64EncodedBodyIsDecoded`,
   `TestHandle_InvalidBase64BodyIsRejected`, `TestHandle_RejectsNegativePrice`,
   `TestHandle_RejectsNegativeRef`, `TestHandle_RejectsOversizeDescription`,
   `TestHandle_AllowsZeroPriceAndRef`.

### Result

- `POST` with a 2 KB `description` → 400 `description exceeds 1KB`.
- `POST` with `price: -1` or `ref: -1` → 400.
- `POST` with a base64-encoded valid body → 200 with the decoded result.
- `POST` with `price: 0, ref: 0` → 200 (unchanged behavior).

---

## Eradication

### Similar Instances

The local fixture (`cmd/products-api/main.go`) and the root `OrdersManager`
client both validate quantities at point of use (`Quantity` type, `> 0`
checks). The Lambda handler was the only unvalidated input surface.

### Prevention Strategy

- Treat every public endpoint as attacker-controlled: bound string fields,
  validate numeric sign, and honor `IsBase64Encoded`.
- Keep the handler test suite in-tree; the auth-gate and validation tests
  are the regression guard for the Function URL's `*` invoke permission.

### Weak Point History

First occurrence. The weak point is `handle()` as the single input gate for
the public Function URL; any future field added to `Request` must be bounded
and validated here.
