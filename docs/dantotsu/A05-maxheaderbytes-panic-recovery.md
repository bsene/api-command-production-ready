# Dantotsu Analysis: products-api missing MaxHeaderBytes and panic recovery

## Problem Statement

The `products-api` HTTP server had no `MaxHeaderBytes` limit (allowing memory
exhaustion via oversized request headers) and no panic-recovery middleware
(meaning an unexpected panic in any handler crashed the entire server process,
taking down all in-flight requests).

---

## Metadata

| Field                   | Value                                                  |
| ----------------------- | ------------------------------------------------------ |
| 🟢 **ID**               | `OWASP-A05-MAXHEADER-RECOVERY`                         |
| 🟢 **Analysis Date**    | `2026/08/19`                                           |
| 🟢 **Project**          | `api-command-kata`                                     |
| 🟢 **Detection Stage**  | `B — Security audit (OWASP Top 10 review)`             |
| 🟢 **Startup**          | `bsene`                                                |
| 🟢 **Status**           | `Fixed` — constant present and enforced by middleware  |
| 🔵 **Weak point**       | `server/server.ml — HTTP server config`               |
| 🟢 **Owner**            | `birrame.sene`                                         |
| 🟢 **napta_project_id** | `api-command`                                          |
| **Standard**            | 🎓 Dantotsu                                            |

---

## User Impact

- **MaxHeaderBytes = 0 (default)**: A client can send a request with
  multi-gigabyte headers. Go's HTTP server allocates memory to buffer them,
  potentially exhausting the process and causing an OOM kill. This is a
  denial-of-service vector.
- **No panic recovery**: A nil-pointer dereference, out-of-bounds slice
  access, or any unexpected panic in the catalog handler (or future
  endpoints) terminates the server. The `http.Server` does not recover panics
  by default — the goroutine dies and, depending on the runtime, the process
  may crash. All concurrent requests are lost.

---

## Causal Chain

1. The `http.Server` struct was configured with timeouts
   (`ReadHeaderTimeout`, `ReadTimeout`, `WriteTimeout`, `IdleTimeout`) but
   `MaxHeaderBytes` was left at the zero default (no limit).
2. No `recover()` middleware was present in the handler chain. The `chain`
   function applied `securityHeaders` and `apiKeyAuth` but neither wraps
   `next` in a `defer recover()`.
3. A panic in the catalog handler's `json.NewEncoder(w).Encode(catalog)` (e.g.,
   if `catalog` were ever mutated concurrently in a future change) propagates
   up the goroutine stack with no recovery, crashing the request goroutine.

---

## Root Cause of Occurrence

The server was hardened incrementally — timeouts and security headers were
added first — but the two remaining hardening items (MaxHeaderBytes, panic
recovery) were not on the same checklist.

### The Misconception

"Go's `http.Server` is safe by default — the timeouts we added cover the
important cases. Panics are programmer errors and shouldn't happen in
production code, so recovery is unnecessary."

### What Actually Happened

1. `http.Server` defaults `MaxHeaderBytes` to `0`, meaning the server
   accepts headers up to available memory. The Go docs explicitly state this
   is unsafe for production.
2. Go's `net/http` server does recover panics in request goroutines since
   Go 1.8+, but only to prevent the whole process from crashing — the
   individual request's response is still broken (the client sees a
   connection reset, not a clean 500). A dedicated recovery middleware
   provides a proper error response and structured logging.
3. "Panics shouldn't happen" is true for known code paths but false for
   future changes, concurrent mutations, and upstream library panics.

### Contributing Factor

The A05 finding in the OWASP audit listed four sub-items (timeouts, security
headers, MaxHeaderBytes, panic recovery) as a single line. The first two were
addressed; the last two were missed because the finding was marked
"partially fixed" without tracking the remaining sub-items.

---

## Detection Failure Causes

### 1. Code Complexity (Local Validation Failure)

The `http.Server` struct literal spans 6 lines and looks complete — it has
four timeout fields. The absence of `MaxHeaderBytes` is a missing line, not a
wrong line, making it easy to overlook.

### 2. Process Gap

No server-hardening checklist was followed. The audit identified the issues
but there was no verification step confirming every sub-item was addressed.

### 3. Missing Tests

No test sent an oversized header to verify rejection. No test triggered a
panic in a handler to verify recovery. The `TestServerConfig_hasMaxHeaderBytes`
test now verifies the constant is set, but a true integration test would
require binding a port (sandbox-restricted).

### 4. Code Review

The reviewer saw the timeout configuration and security headers and assumed
the server was fully hardened. The two missing items were not on a
reviewer checklist.

---

## Countermeasure

### Changes Made

1. **MaxHeaderBytes**: Set `max_header_bytes = 1 << 20` (1 MiB) in
   `server/server.ml` and added `enforce_max_header_bytes` middleware. Dream
   has no built-in per-server header-size cap, so the middleware measures the
   parsed header set plus the HTTP/1.1 request line and rejects requests whose
   total header bytes exceed 1 MiB with `431 Request Header Fields Too Large`.
   This prevents memory exhaustion from oversized headers while leaving ample
   room for legitimate requests (the API key, content-type, etc. are well under
   1 KB).

2. **Panic recovery middleware**: Added `recover logger` middleware using
   `Lwt.catch`. It catches exceptions/rejections from the downstream handler and:
   - Logs the panic with method, path, remote address, and the exception text
     via the structured logger.
   - Writes a clean `500 Internal Server Error` response.
   - Does NOT re-raise the exception (the request promise resolves cleanly so
     the process stays alive).

3. **Middleware ordering**: The chain is now
   `request_logger → recover → enforce_max_header_bytes → security_headers →
   api_key_auth → router`. Recovery wraps everything downstream so panics from
   the size gate, auth, headers, or the handler are all caught and logged.
   Security headers wrap the 431 produced by the size gate, just as they wrap
   the 401 from auth and the 500 from recovery.

4. **Tests**:
   - `TestRecoveryMiddleware_recoversPanic` — handler panics, middleware
     returns 500.
   - `TestRecoveryMiddleware_passesThroughWhenNoPanic` — no panic, normal
     response.
   - `TestServerConfig_hasMaxHeaderBytes` — verifies `max_header_bytes` is set
     to `1 << 20`.
   - `TestMaxHeaderBytes_rejectsOversizedHeaders` — in-process Dream request
     with a header larger than 1 MiB is rejected with 431.
   - `TestMaxHeaderBytes_allowsNormalHeaders` — ordinary header set passes
     through with 200.
   - `TestIntegration_maxHeaderBytesWiredInApp` — the full production
     `Server.app` handler also rejects oversized headers with 431, confirming
     the middleware is wired into the deployed chain.

### Result

- Oversized headers (>1 MiB) are rejected by the `enforce_max_header_bytes`
  middleware with `431 Request Header Fields Too Large` before reaching any
  handler or downstream middleware.
- A panic in any handler or middleware is caught, logged with context, and
  returns a clean 500 — the process survives and other requests continue.
- Security headers are still set on 500 responses (recovery middleware is
  inside the security headers middleware in the chain) and on the 431 response
  produced by the size gate.

---

## Eradication

### Similar Instances

The `server/` server is the only HTTP server in the codebase. The
`Orders_manager` is a client, not a server, and is not affected.

### Prevention Strategy

- Create a server-hardening checklist that must be verified for every HTTP
  server: timeouts (read/header/write/idle), a header-size cap equivalent to
  Go's `MaxHeaderBytes`, and panic-recovery middleware.
- Add a code review checklist item: "Every HTTP server must enforce a
  non-zero request header size limit." For Dream/Opium servers that lack a
  built-in cap, this must be implemented as middleware and wired into the
  production handler chain.
- Add a review checklist item: "Every HTTP handler chain must include a
  panic-recovery middleware."

### Weak Point History

First occurrence. The weak point is the HTTP server configuration and
middleware chain in `server/server.ml`. Any future endpoint added to the router
is automatically protected by the size gate and recovery middleware because
of the chain ordering.
