# Dantotsu Analysis: No structured logging of requests, errors, or cart validation failures

## Problem Statement

Neither the `OrdersManager` client nor the `products-api` server produced any
structured logs. There were no access logs, no audit trail of outbound
requests, no logging of cart validation failures, and no logging of upstream
API errors. Security incidents and operational issues were invisible.

---

## Metadata

| Field                   | Value                                                  |
| ----------------------- | ------------------------------------------------------ |
| 🟢 **ID**               | `OWASP-A09-LOGGING`                                    |
| 🟢 **Analysis Date**    | `2026/08/19`                                           |
| 🟢 **Project**          | `api-command-kata`                                     |
| 🟢 **Detection Stage**  | `B — Security audit (OWASP Top 10 review)`             |
| 🟢 **Startup**          | `bsene`                                                |
| 🟢 **Status**           | `Fixed`                                                |
| 🔵 **Weak point**       | `orders_manager.go + cmd/products-api/main.go`         |
| 🟢 **Owner**            | `birrame.sene`                                         |
| 🟢 **napta_project_id** | `api-command`                                          |
| **Standard**            | 🎓 Dantotsu                                            |

---

## User Impact

- **No access logs**: When the products-api server receives requests, there
  is no record of who called what endpoint, when, or with what result. A
  brute-force attack on the `x-api-key` header (repeated 401s) is invisible.
- **No outbound request logging**: The `OrdersManager` makes HTTP requests to
  the products API with no trace. If the upstream is down or returning errors,
  there is no log evidence — only the returned Go error, which callers may
  discard.
- **No cart validation audit**: When `ValidateCart` rejects items (negative
  quantity, insufficient stock, unknown product), no structured record is
  emitted. A pattern of repeated validation failures (potential fraud or
  abuse) is undetectable.
- **No upstream error logging**: Non-200 responses from the products API are
  returned as errors but not logged with context (URL, status, timing).

---

## Causal Chain

1. The `OrdersManager` used no logging library — `fetchProducts` built a
   request, called `m.client.Do`, and returned errors as Go `error` values
   with no side-channel logging.
2. The `products-api` server used `log.Printf` for startup messages but had
   no per-request access log. The catalog handler logged encode errors via
   `log.Printf` but nothing else.
3. No `slog` (or any structured logger) was configured anywhere in the
   codebase.
4. The OWASP audit flagged this as A09 (Security Logging and Monitoring
   Failures) but no remediation was applied.

---

## Root Cause of Occurrence

Logging was treated as an operational concern, not a security control, and
deferred indefinitely.

### The Misconception

"Logging is nice-to-have for debugging but not a security requirement. The
Go error return values carry enough information for the caller to handle
failures. We can add logging later if we need it."

### What Actually Happened

1. Security logging is a first-class OWASP category (A09). Without it, there
   is no audit trail for incident response, no detection of brute-force auth
   attempts, and no visibility into upstream failures.
2. Go error values are consumed by the immediate caller and then discarded —
   they don't persist. A log line persists to stderr/file/SIEM and can be
   correlated across requests and time.
3. "Add logging later" never happens because there's no trigger — the system
   appears to work, and the absence of logs is only noticed during an
   incident when it's too late.

### Contributing Factor

Go 1.21+ includes `log/slog` in the standard library (no third-party
dependency needed), but the codebase predates the adoption of `slog` or was
written without awareness of it. The `go.mod` declares `go 1.26.1`, so
`log/slog` is available.

---

## Detection Failure Causes

### 1. Code Complexity (Local Validation Failure)

Logging is cross-cutting — it touches every request path but belongs to no
single function. Without a middleware or wrapper pattern, adding it requires
modifying every call site, which makes it feel like a large change and gets
deferred.

### 2. Process Gap

No "logging checklist" was part of the security audit remediation. The A09
finding was noted but not assigned a remediation task, unlike A01 (auth) and
A02 (TLS) which had concrete code changes.

### 3. Missing Tests

There were no tests asserting log output because there was no logging. A
test that captures `slog` output and asserts on log fields (level, message,
status, elapsed) would verify logging is present and correct.

### 4. Code Review

The reviewer focused on functional correctness and the security controls
they could see (auth, TLS, headers). Logging is invisible in a diff — you
have to specifically look for its absence, which requires a checklist item.

---

## Countermeasure

### Changes Made

**OrdersManager client** (`orders_manager.go`):

1. Added a `logger *slog.Logger` field, defaulting to `slog.Default()`.
2. Added `WithLogger(logger *slog.Logger)` option for dependency injection
   (useful for testing — inject a logger writing to `io.Discard`).
3. `fetchProducts` now logs:
   - `slog.Error` — request build failure (with base URL + error).
   - `slog.Error` — request failure (with URL, elapsed, error).
   - `slog.Warn` — non-200 response (with URL, status, elapsed).
   - `slog.Error` — JSON decode failure (with URL, status, error).
   - `slog.Info` — successful request (with URL, status, product count,
     elapsed).
4. `ValidateCart` logs `slog.Warn` when validation fails (with item count,
   invalid count, and details).

**products-api server** (`cmd/products-api/main.go`):

1. Created a `slog.Logger` with `slog.NewTextHandler(os.Stderr, ...)`.
2. Added `requestLogger(logger)` middleware that logs every request with:
   - `slog.Info` — method, path, status, remote address, elapsed_ms.
   - Uses a `statusRecorder` wrapper to capture the response status code.
3. The catalog handler's encode error now logs via `slog.Error` instead of
   `log.Printf`.
4. Startup messages use `slog.Info` with structured fields (addr, tls).
5. The `recoveryMiddleware` (added for A05) logs panics via `slog.Error` with
   method, path, remote, and panic value.

### Result

- Every inbound HTTP request to the products-api is logged with method,
  path, status, remote address, and elapsed time.
- Every outbound HTTP request from `OrdersManager` is logged with URL,
  status, product count, and elapsed time.
- Cart validation failures are logged with item counts and per-item details.
- Upstream errors (non-200, decode failures, network errors) are logged at
  Error/Warn level with full context.
- All logs use structured key-value pairs (slog), enabling filtering and
  correlation in a SIEM or log aggregator.

---

## Eradication

### Similar Instances

Every HTTP call site in the codebase now logs. The `findProduct` method
delegates to `fetchProducts` and inherits logging. No other outbound HTTP
call sites exist. The server has a single mux with a single route; the
request logger middleware covers all routes automatically.

### Prevention Strategy

- Make `slog` the mandatory logging interface for all new code. Add a review
  checklist item: "Every new HTTP handler or outbound HTTP call must log at
  Info (success) and Error/Warn (failure) with structured fields."
- Consider adding a test that captures slog output and asserts on expected
  log lines for critical paths (auth failure, cart validation failure,
  upstream error).
- Document the logging contract in the README: what is logged, at what level,
  with what fields.

### Weak Point History

First occurrence. The weak point is the cross-cutting nature of logging — it
touches every request path but belongs to no single component. The middleware
pattern (server) and the centralized `fetchProducts` (client) ensure all
paths are covered, but any new call site added outside these patterns would
need its own logging.
