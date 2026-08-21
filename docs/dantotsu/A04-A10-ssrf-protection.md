# Dantotsu Analysis: SSRF — attacker-controllable baseURL targeting internal endpoints

## Problem Statement

The `OrdersManager.baseURL` was fully attacker-controllable and used for
outbound HTTP with no restriction on the target host. A malicious or
misconfigured URL could direct requests to cloud metadata endpoints
(`169.254.169.254`), loopback services, or private subnets, enabling
server-side request forgery (SSRF).

---

## Metadata

| Field                   | Value                                                          |
| ----------------------- | -------------------------------------------------------------- |
| 🟢 **ID**               | `OWASP-A04-A10-SSRF`                                           |
| 🟢 **Analysis Date**    | `2026/08/19`                                                   |
| 🟢 **Project**          | `api-command-kata`                                             |
| 🟢 **Detection Stage**  | `B — Security audit (OWASP Top 10 review)`                     |
| 🟢 **Startup**          | `bsene`                                                        |
| 🟢 **Status**           | `⚠️ Partial — one item deferred`                               |
| 🔵 **Weak point**       | `lib/orders_manager.ml + lib/ssrf.ml — validate_base_url + HTTP transport dialer` |
| 🟢 **Owner**            | `birrame.sene`                                                 |
| 🟢 **napta_project_id** | `api-command`                                                  |
| **Standard**            | 🎓 Dantotsu                                                    |

---

## Remediation status (1b)

**A04/A10 — SSRF protection**

Status: ⚠️ Partial — one item deferred

- ✅ `validate_base_url` enforces scheme + IP-literal check at URL-time — `lib/ssrf.ml:20-33`
- ✅ `check_ssrf_ip` classifies link-local, unspecified, multicast, loopback, private — `lib/ssrf.ml:5-18`
- ✅ URL parsing via `Uri.of_string` replaces `strings.HasPrefix` — `lib/ssrf.ml:22-23`
- ✅ Dial-time IP check for hostnames (in `lib/cohttp_backend.ml`) — present
- ✅ DNS rebinding defense (resolved once, used directly) — present in backend
- ❌ **Deferred:** "Consider adding a CI grep check that fails if `WithHTTPClient` appears outside `*_test.go` files." This exists as documentation only, not enforcement.

---

## User Impact

If the `baseURL` is derived from external input (configuration, user request
data, a database record), an attacker can set it to `http://169.254.169.254`
(AWS/GCP/Azure metadata service) and the `OrdersManager` will dutifully fetch
`/products` from that endpoint, potentially exfiltrating cloud instance
credentials or probing internal services. Even without malicious intent, a
typo like `https://10.0.0.1` causes silent requests to an internal host with
no error or warning.

---

## Causal Chain

1. `NewOrdersManager(baseURL, opts)` stores `baseURL` after trimming trailing
   slashes and validates only the URL scheme (`https://` required, `http://`
   allowed with `WithInsecureHTTP`).
2. No host or IP validation is performed — the scheme check does not
   distinguish `https://products.com` (safe) from `https://169.254.169.254`
   (metadata endpoint) or `https://10.0.0.1` (private subnet).
3. `fetchProducts` constructs `m.baseURL + "/products"` and calls
   `m.client.Do(req)`. The default `http.Client` uses
   `http.DefaultTransport`, which dials whatever IP the hostname resolves to
   — including loopback, private, and link-local addresses.
4. No DNS-rebinding protection exists: a hostname that resolves to a public
   IP at validation time can resolve to a private IP at request time.

---

## Root Cause of Occurrence

SSRF was not considered a threat because the `baseURL` was assumed to always
be a developer-controlled constant (`https://products.com`).

### The Misconception

"The `baseURL` is hardcoded by the developer, so it's always trusted. There's
no need to validate the target host — only the scheme matters (HTTPS for
encryption)."

### What Actually Happened

1. The `baseURL` is a parameter to `NewOrdersManager`, meaning any caller can
   pass any string. In a real deployment, this could come from configuration,
   environment variables, or request data.
2. Even when the developer controls the URL, defense-in-depth requires that
   the client refuse to connect to known-dangerous targets (metadata
   endpoints, private subnets) regardless of who set the URL.
3. The `http.Client` default transport has no built-in SSRF protection — it
   happily dials any IP, including `169.254.169.254`.

### Contributing Factor

The original code validated the URL scheme with `strings.HasPrefix` rather
than `net/url.Parse`, which also missed malformed URLs, missing hosts, and
non-HTTP schemes (e.g., `ftp://`, `file://`).

---

## Detection Failure Causes

### 1. Code Complexity (Local Validation Failure)

`validateBaseURL` was a 10-line function doing string prefix checks. It looked
correct at a glance — "rejects http://, requires https://" — but the
hostname/IP was never examined.

### 2. Process Gap

The security audit checked for SSRF as a category but the finding was
filed alongside the scheme-validation issue (A02). The distinction between
"wrong scheme" (cryptographic) and "wrong target host" (SSRF) was not
separated into distinct remediation tasks.

### 3. Missing Tests

No test attempted to construct an `OrdersManager` with a metadata IP, private
IP, or loopback IP as the base URL. The test suite only covered
`https://products.com` and `http://127.0.0.1:18080` (with `WithInsecureHTTP`).

### 4. Code Review

The `validateBaseURL` function was reviewed for scheme correctness but not
for host safety. The reviewer focused on "does it enforce HTTPS?" rather
than "does it prevent connecting to internal services?"

---

## Countermeasure

### Changes Made

1. **URL parsing**: Replaced `strings.HasPrefix` checks with `net/url.Parse`,
   validating scheme (`http`/`https` only), presence of a host, and rejecting
   non-HTTP schemes.

2. **URL-time IP check**: If the host is an IP literal (e.g.,
   `https://169.254.169.254`), `checkSSRFIP` is called immediately during
   `validateBaseURL`.

3. **Dial-time SSRF-safe transport**: `newSSRFSafeTransport` returns an
   `*http.Transport` with a custom `DialContext` that:
   - Resolves the hostname to IP addresses via `net.DefaultResolver.LookupIPAddr`.
   - Checks every resolved IP with `checkSSRFIP` before connecting.
   - Dials the first verified-safe IP directly (bypassing a second DNS
     resolution that could return a different, blocked address — DNS
     rebinding defense).

4. **`checkSSRFIP` rules**:
   - **Always blocked**: link-local unicast/multicast (169.254.0.0/16,
     fe80::/10 — includes cloud metadata), unspecified (0.0.0.0, ::),
     multicast.
   - **Blocked in production mode** (default): loopback (127.0.0.0/8, ::1),
     private (10/8, 172.16/12, 192.168/16, fc00::/7).
   - **Allowed in local-dev mode** (`WithInsecureHTTP`): loopback and private
     (so the in-process fixture on `127.0.0.1` works), but link-local/metadata
     remains blocked.

5. **Tests**: 10 new test cases covering metadata IP rejection, private IP
   rejection, loopback rejection (HTTPS), loopback allowance (local-dev),
   unspecified IP rejection, invalid scheme rejection, and unit tests for
   `checkSSRFIP` across all ranges.

### Result

- `NewOrdersManager("https://169.254.169.254")` → error at construction.
- `NewOrdersManager("https://10.0.0.1")` → error at construction.
- `NewOrdersManager("http://127.0.0.1:18080", WithInsecureHTTP())` → allowed
  (local dev), but `169.254.169.254` is still blocked even with
  `WithInsecureHTTP`.
- DNS rebinding: even if a hostname passes URL validation, the dial-time
  check rejects any resolved IP in a blocked range.
- `WithHTTPClient` bypasses the SSRF-safe transport (documented); this is
  intended for test mocks only.

---

## Eradication

### Similar Instances

No other outbound HTTP call sites exist in the codebase. The
`findProduct` method delegates to `fetchProducts`, so it inherits the
protection. The `server/` server makes no outbound requests.

### Prevention Strategy

- The SSRF-safe transport is the default for all `OrdersManager` instances.
  The test-only HTTP backend bypass is confined to `lib/test/`.
- Lint/documentation rule in place: "Never use the test-only HTTP backend in
  production code; it bypasses SSRF protection."
- ❌ **Deferred:** CI grep check that fails if the SSRF-bypass backend appears
  outside test files. Currently documented only, not enforced.

### Weak Point History

First occurrence. The weak point is the `OrdersManager` client as the sole
outbound HTTP consumer. Any future outbound HTTP client in this codebase must
reuse `Cohttp_backend` or `Ssrf.check_ssrf_ip`.
