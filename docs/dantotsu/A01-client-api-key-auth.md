# Dantotsu Analysis: OrdersManager client did not authenticate to the products API

## Problem Statement

The `OrdersManager` client made outbound requests to the products API without
sending any credentials. After the server fixture was hardened to require an
`x-api-key` header (A01 server-side fix), the client could no longer
communicate with it — every request returned `401 Unauthorized`.

---

## Metadata

| Field                   | Value                                                  |
| ----------------------- | ------------------------------------------------------ |
| 🟢 **ID**               | `OWASP-A01-CLIENT-AUTH`                                |
| 🟢 **Analysis Date**    | `2026/08/19`                                           |
| 🟢 **Project**          | `api-command-kata`                                     |
| 🟢 **Detection Stage**  | `B — Security audit (OWASP Top 10 review)`             |
| 🟢 **Startup**          | `bsene`                                                |
| 🟢 **Status**           | `Fixed`                                                |
| 🔵 **Weak point**       | `lib/orders_manager.ml — Orders_manager HTTP client`    |
| 🟢 **Owner**            | `birrame.sene`                                         |
| 🟢 **napta_project_id** | `api-command`                                          |
| **Standard**            | 🎓 Dantotsu                                            |

---

## User Impact

Any caller using `OrdersManager` against an authenticated products API instance
receives a `"products API returned status 401"` error for every method call
(`AllDescriptions`, `AvailableDescriptions`, `IsAvailable`, `Search`,
`ValidateCart`). The client is completely non-functional against a
properly-configured server, forcing callers to either disable server-side
authentication (reintroducing A01) or bypass the client entirely.

---

## Causal Chain

1. The server fixture (`server/server.ml`) was hardened with `api_key_auth`
   middleware requiring an `x-api-key` header on every request.
2. The `Orders_manager` client in `lib/orders_manager.ml` was not updated to send
   that header — `fetchProducts` builds a `GET` request with no authentication
   headers.
3. When the client calls the authenticated server, the `apiKeyAuth` middleware
   sees an empty `x-api-key` header, returns `401 Unauthorized`, and
   `fetchProducts` surfaces `"products API returned status 401"`.
4. Every public method on `OrdersManager` fails because they all funnel
   through `fetchProducts`.

---

## Root Cause of Occurrence

The server-side A01 fix and the client-side A01 fix were treated as a single
task but only the server side was implemented. The client was left
incompatible.

### The Misconception

"Adding authentication to the server is sufficient to close A01 — the client
will work because it's part of the same codebase and will naturally pick up
the requirement."

### What Actually Happened

1. Authentication is a two-party protocol: the server must enforce it AND the
   client must present credentials. Fixing only one side breaks the channel.
2. The `OrdersManager` had no mechanism to accept or store an API key — no
   field, no option, no header-setting code.
3. The test suite used a `fakeTransport` mock that bypasses real HTTP entirely,
   so the missing header was invisible in tests.

### Contributing Factor

The security audit was performed on a snapshot and reported server + client
findings together under a single A01 line item, without separating the
server-side and client-side remediation steps.

---

## Detection Failure Causes

### 1. Code Complexity (Local Validation Failure)

The `fetchProducts` method builds an `http.Request` and calls `m.client.Do(req)`.
The request is constructed with no headers beyond what `http.NewRequestWithContext`
sets by default. The absence of an auth header is not visually striking — it
blends into a 4-line function body.

### 2. Process Gap

No integration test exercises the full client↔server path with authentication
enabled. The Hurl smoke tests test the server directly; the Go unit tests test
the client with a mock transport. The gap between them is untested.

### 3. Missing Tests

A test asserting `transport.seen.Header.Get("x-api-key") != ""` when an API
key is configured would have caught this immediately. No such test existed.

### 4. Code Review

The server-side auth fix was reviewed and merged; the client-side
counterpart was assumed to be a trivial follow-up that didn't require its own
review.

---

## Countermeasure

### Changes Made

- Added an `apiKey` field to `OrdersManager` and a `WithAPIKey(key string)`
  `Option`.
- In `fetchProducts`, the `x-api-key` header is set on every outbound request
  when `m.apiKey` is non-empty.
- Added tests `TestFetchProducts_sendsAPIKeyHeader` and
  `TestFetchProducts_omitsAPIKeyWhenNotSet` to verify both the presence and
  absence of the header.

### Result

A caller can now do `NewOrdersManager("https://...", WithAPIKey("secret"))`
and all requests carry the `x-api-key: secret` header, passing the server's
`apiKeyAuth` middleware. When no key is configured, the header is omitted
(backward-compatible with unauthenticated servers).

---

## Eradication

### Similar Instances

The `findProduct` method also calls `fetchProducts`, so it inherits the fix
automatically. No other outbound HTTP call sites exist in the codebase.

### Prevention Strategy

- Document the client↔server auth contract in the `OrdersManager` docstring:
  "When the products API enforces authentication, pass `WithAPIKey`."
- ✅ **Implemented** — Add a CI check (or integration-test scenario) that
  boots the authenticated fixture and calls `OrdersManager` against it
  end-to-end, failing if any method returns 401. Delivered as
  `integration/client_smoke.exe` (driven by `task integration:client`, folded
  into `task smoke`), which builds the real SSRF-safe `Cohttp_backend` and
  asserts that a manager with the wrong `x-api-key` fails while one with the
  right key succeeds.

### Weak Point History

First occurrence. The weak point is the `fetchProducts` method as the single
outbound HTTP call site — any future authentication mechanism (OAuth, mTLS)
must be wired through here.
