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
| 🔵 **Weak point**       | `lib/orders_manager.ml + server/server.ml`             |
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

1. The `Orders_manager` client used no logging library — `fetch_products` built a
   request, called the HTTP backend, and returned errors as OCaml `result`
   values with no side-channel logging.
2. The products-api server had no per-request access log. The catalog handler
   logged nothing on error.
3. No structured logger was configured anywhere in the codebase.
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

The OCaml port ships a small `Log` module (`lib/log.ml`) emitting Go-slog
-style text-handler lines (level=INFO/WARN/ERROR, key=value pairs) into a
buffer and optionally stdout. No third-party logging library is needed; the
port predates any structured logger in the codebase.

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
test that captures `Log` output and asserts on log fields (level, message,
status, elapsed) would verify logging is present and correct.

### 4. Code Review

The reviewer focused on functional correctness and the security controls
they could see (auth, TLS, headers). Logging is invisible in a diff — you
have to specifically look for its absence, which requires a checklist item.

---

## Countermeasure

### Changes Made

**Orders_manager client** (`lib/orders_manager.ml`):

1. Added a `mutable logger : Log.t` field, defaulting to `Log.create ()`.
2. Added `set_logger` for dependency injection (tests inject a logger and
   assert on `Log.contents`).
3. `fetch_products` now logs via `Log.info`/`Log.warn`/`Log.error`:
   - `Log.error` — request build failure (with URL + error).
   - `Log.error` — request failure (with URL, elapsed, error).
   - `Log.warn` — non-200 response (with URL, status, elapsed).
   - `Log.error` — JSON decode failure (with URL, status, error).
   - `Log.info` — successful request (with URL, status, product_count,
     elapsed).
4. `validate_cart` logs `Log.warn` when validation fails (with item_count,
   invalid_count, and details).

**products-api server** (`server/server.ml`):

1. The `Log` module writes `level=... msg="..." k=v` lines; production entry
   points pass `~out:stdout`.
2. Added `request_logger` middleware that logs every request with:
   - `Log.info` — method, path, status, remote, elapsed_ms.
   - Reads the status from the response after the inner handler runs
     (mirroring Go's `statusRecorder`).
3. The catalog handler's encode error now logs via `Log.error` instead of
   nothing.
4. Startup messages use `Log.info` with structured fields (addr, tls).
5. The `recover` middleware (added for A05) logs exceptions via `Log.error`
   with method, path, remote, and panic value.

### Result

- Every inbound HTTP request to the products-api is logged with method,
  path, status, remote address, and elapsed time.
- Every outbound HTTP request from `OrdersManager` is logged with URL,
  status, product count, and elapsed time.
- Cart validation failures are logged with item counts and per-item details.
- Upstream errors (non-200, decode failures, network errors) are logged at
  Error/Warn level with full context.
- All logs use structured key-value pairs (`Log` module), enabling filtering
  and correlation in a SIEM or log aggregator.

---

## Eradication

### Similar Instances

Every HTTP call site in the codebase now logs. The `is_available` method
delegates to `fetch_products` and inherits logging. No other outbound HTTP
call sites exist. The server has a single mux with a single route; the
request logger middleware covers all routes automatically.

### Prevention Strategy

- Make the `Log` module the mandatory logging interface for all new code. Add
  a review checklist item: "Every new HTTP handler or outbound HTTP call must
  log at Info (success) and Error/Warn (failure) with structured fields."
- Consider adding a test that captures `Log` output and asserts on expected
  log lines for critical paths (auth failure, cart validation failure,
  upstream error).
- Document the logging contract in the README: what is logged, at what level,
  with what fields.

### Weak Point History

First occurrence. The weak point is the cross-cutting nature of logging — it
touches every request path but belongs to no single component. The middleware
pattern (server) and the centralized `fetch_products` (client) ensure all
paths are covered, but any new call site added outside these patterns would
need its own logging.
