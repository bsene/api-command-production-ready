# Dantotsu Analysis: public Function URL had no rate limiting or concurrency cap

## Problem Statement

The Lambda Function URL is public (`authorizationType: "NONE"`, `principal: "*"`)
with no WAF, CloudFront, or per-caller throttling in front of it, and the
function had no reserved-concurrency cap. Anyone could hammer the endpoint; the
only gate was the application-level `x-api-key` check.

---

## Metadata

| Field                   | Value                                                  |
| ----------------------- | ------------------------------------------------------ |
| 🟢 **ID**               | `OWASP-A05-RATE-LIMITING`                              |
| 🟢 **Analysis Date**    | `2026/08/20`                                           |
| 🟢 **Project**          | `api-command-kata`                                     |
| 🟢 **Detection Stage**  | `B — Security audit (OWASP Top 10 review)`             |
| 🟢 **Startup**          | `bsene`                                                |
| 🟢 **Status**           | `Fixed`                                                |
| 🔵 **Weak point**       | `infra/src/index.ts — Lambda Function URL`             |
| 🟢 **Owner**            | `birrame.sene`                                         |
| 🟢 **napta_project_id** | `api-command`                                          |
| **Standard**            | 🎓 Dantotsu                                            |

---

## User Impact

An attacker (or a misbehaving client) can send sustained invocations to the
public endpoint with no per-caller throttling. Consequences:

- **Brute-force on `LAMBDA_API_KEY`**: if the operator chose a weak or short
  key, an attacker can guess it with no lockout or exponential backoff, then
  impersonate a legitimate caller.
- **Billing/cost DoS**: every invocation is billable; sustained traffic drives
  up cost with no upper bound.
- **Concurrency exhaustion**: without a reserved-concurrency cap, a flood can
  consume the account's concurrency pool and starve other functions.

---

## Causal Chain

1. `infra/src/index.ts` provisions a `aws.lambda.FunctionUrl` with
   `authorizationType: "NONE"` and grants `lambda:InvokeFunctionUrl` (and
   `lambda:InvokeFunction`) to `principal: "*"`.
2. No CloudFront distribution, WAF web ACL, or rate-based rule is placed in
   front of the Function URL.
3. The `aws.lambda.Function` is created without `reservedConcurrentExecutions`,
   so it can scale up to the account's concurrency limit.
4. The only access control is the handler's constant-time `x-api-key`
   comparison (`lambda/lambda_handler.ml`), which originally had no lockout or
   backoff.
5. A flood of requests therefore reaches the handler unchecked; a weak key can
   be brute-forced, and cost/concurrency are unbounded.

---

## Root Cause of Occurrence

The Function URL was treated as "authenticated enough" because the handler
checks `x-api-key`, so the edge-level resource controls were skipped.

### The Misconception

"Application-level authentication is sufficient — the handler rejects
unauthenticated callers with 401, so rate limiting and concurrency caps are
unnecessary."

### What Actually Happened

1. Authentication and rate limiting are orthogonal controls: the key check
   stops *unauthenticated* callers, but does nothing to bound *authenticated*
   (or brute-forcing) traffic volume.
2. The Function URL is reachable from the public internet with no edge
   throttling, so the handler is the only line of defense.
3. The key strength was left entirely to the operator — nothing enforced a
   minimum length, so a short key made brute-force feasible.

### Contributing Factor

The infra was built incrementally (Function URL → permissions → handler auth),
and each step was reviewed for correctness of the auth gate, not for
resource-consumption or key-strength properties.

---

## Detection Failure Causes

### 1. Code Complexity (Local Validation Failure)

The absence of `reservedConcurrentExecutions` is invisible in a Pulumi program
— it is an omitted property, not a wrong value, so it does not stand out in
review.

### 2. Process Gap

No checklist item required a rate-limiting / resource-consumption review for
new public endpoints. The code-review checklist covers A04/A05/A09 for the
client and fixture, but not the Lambda Function URL.

### 3. Missing Tests

No test or preview assertion checked that the function has a reserved
concurrency cap or that the API key meets a minimum length.

### 4. Code Review

Review focused on the auth gate (A01) and the Function URL permission model;
the "what happens when traffic is legitimate but unbounded" question was not
asked.

---

## Countermeasure

### Changes Made

- Added `reservedConcurrentExecutions` to the Lambda function, sourced from
  `pulumi config getNumber("reservedConcurrency")` with a default of `5`, so a
  flood cannot exhaust the account's concurrency pool.
- Validated the API key at deploy time in `infra/src/index.ts`: a key shorter
  than 32 bytes fails `pulumi preview`/`up` with a clear error.
- Added a defense-in-depth startup guard in `lambda/lambda_handler.ml`: the
  handler refuses to serve (500) if `LAMBDA_API_KEY` is missing or shorter than
  32 bytes.
- **Added a handler-level per-IP fixed-window rate limiter** (`lambda/rate_limit.ml`):
  120 requests / 60s / IP, enforced **before** the auth check (all-requests
  policy) so a flood of unauthenticated calls is throttled without reaching
  the key comparison. Over-limit requests get `429` with a `Retry-After`
  header. The table is in-memory with a bounded LRU (~1024 IPs). The caller IP
  is decoded from `requestContext.http.sourceIp` in `lambda/event.ml`.
- Documented the ≥32-byte key requirement, the `openssl rand -hex 32`
  generation command, and the reserved-concurrency override in
  `infra/README.md`.

### Result

A weak key can no longer be deployed (blocked at both Pulumi and handler
startup), the function's concurrency is bounded so a flood cannot starve
other functions or drive unbounded cost, and a single caller exceeding
120 req/min is throttled with `429` + `Retry-After`. CloudFront + WAF
rate-based rules remain the deferred full-edge option for edge-level
per-caller throttling.

### Residual risk accepted

The one remaining M1 gap is accepted for the prototype rather than built:

- **No WAF/CloudFront edge throttle** — reserved concurrency (default 5) already
  bounds cost-DoS and concurrency exhaustion, and the handler-level per-IP
  limiter now bounds a single caller, so no edge layer is added.

The handler-level per-IP lockout is **best-effort**, with a documented caveat:
the table is per execution environment, so it resets on cold start and is *not*
shared across parallel Lambda instances. Under horizontal scale an attacker can
exceed the per-instance cap across instances; it is a backstop, not a hard edge
limit. CloudFront + WAF rate-based rules remain the deferred full-edge option
if the endpoint is ever promoted beyond a prototype.

---

## Eradication

### Similar Instances

The local fixture (`server/main.exe`) is loopback-only and not internet-facing,
so it is not exposed to the same public-endpoint risk. No other public AWS
endpoints exist in this repo.

### Prevention Strategy

- Add a checklist item to `docs/checklists/code-review.md`: any new public
  endpoint must bound resource consumption (reserved concurrency, rate limit,
  or WAF) and enforce a minimum key strength.
- Keep the key-strength rule in a single place (the Pulumi program) and mirror
  it in the handler so a misconfigured deploy fails closed.

### Weak Point History

First occurrence. The weak point is the Function URL provisioning in
`infra/src/index.ts` — any future public endpoint must apply the same
concurrency and key-strength controls.
