# api-command

Kata: [Préparation de commandes](https://github.com/xnopre/xnopre-katas/blob/master/api_command.md)

`OrdersManager` consumes the fictional products API (`https://products.com`) to
prepare sports-product orders.

## Layout

- `orders_manager.go` — the `OrdersManager` client (list, availability, search, cart validation)
- `product.go` — wire types (`Product`, `CartItem`, `CartValidation`, …)
- `orders_manager_test.go` — unit tests (mocked HTTP transport)
- `cmd/products-api` — a real HTTP server emulating the products API, used as the smoke-test target
- `smoke-tests/*.hurl` — QA smoke scenarios, run with the `hurl` tool against a real server
- `docs/dantotsu/` — Dantotsu defect-analysis reports for each fixed OWASP issue

## Security

The products API fixture and the `OrdersManager` client include OWASP-aligned
controls. Each control has a Dantotsu root-cause analysis under `docs/dantotsu/`.

- **A01 – Broken Access Control**
  - The fixture authenticates every request with an `x-api-key` header
    (`-api-key` flag / `PRODUCTS_API_KEY` env); anonymous calls get `401`.
  - The listen address defaults to loopback and refuses non-loopback binds
    unless `-allow-external` is passed, preventing accidental exposure.
  - The `OrdersManager` client sends `x-api-key` via the `WithAPIKey` option
    when the upstream API requires authentication.
  - Report: [docs/dantotsu/A01-client-api-key-auth.md](docs/dantotsu/A01-client-api-key-auth.md)

- **A02 – Cryptographic Failures**
  - `NewOrdersManager` rejects plain `http://` base URLs by default; use
    `WithInsecureHTTP()` only for the local dev fixture.
  - `WithTLSConfig(*tls.Config)` pins TLS verification (custom RootCAs /
    MinVersion) on the client.
  - The fixture can serve HTTPS via `-tls-cert` / `-tls-key`, and sets
    `Strict-Transport-Security` over TLS plus baseline defensive headers.

- **A04 – Insecure Design**
  - **SSRF protection**: the base URL host is validated at construction time
    (IP-literal check) and at dial time (DNS resolution + IP range check) to
    prevent requests to cloud metadata endpoints (`169.254.169.254`),
    loopback, private subnets, and link-local addresses. See
    [docs/dantotsu/A04-A10-ssrf-protection.md](docs/dantotsu/A04-A10-ssrf-protection.md).
  - **Negative quantity validation**: `ValidateCart` rejects zero or negative
    `CartItem.Quantity` values (`CartItemInvalidQuantity` reason), preventing
    cart-total manipulation. See
    [docs/dantotsu/A04-negative-quantity-validation.md](docs/dantotsu/A04-negative-quantity-validation.md).

- **A05 – Security Misconfiguration**
  - The server sets `ReadHeaderTimeout`, `ReadTimeout`, `WriteTimeout`,
    `IdleTimeout`, and `MaxHeaderBytes` (1 MiB).
  - A `recoveryMiddleware` catches panics in any handler or middleware, logs
    them, and returns a clean `500` instead of crashing the process.
  - Security headers (`X-Content-Type-Options`, `X-Frame-Options`,
    `Cache-Control`, `Content-Security-Policy`, HSTS over TLS) are set on
    every response.
  - Report: [docs/dantotsu/A05-maxheaderbytes-panic-recovery.md](docs/dantotsu/A05-maxheaderbytes-panic-recovery.md)

- **A09 – Security Logging and Monitoring Failures**
  - The server logs every request (method, path, status, remote, elapsed) via
    `slog` structured logging through the `requestLogger` middleware.
  - The `OrdersManager` logs outbound requests (URL, status, count, elapsed),
    upstream errors, and cart validation failures at appropriate levels.
  - Report: [docs/dantotsu/A09-structured-logging.md](docs/dantotsu/A09-structured-logging.md)

- **A10 – Server-Side Request Forgery (SSRF)**
  - See A04 SSRF protection above — the same countermeasure addresses A10.

## Options reference

| Option | Purpose |
|---|---|
| `WithAPIKey(key)` | Sets the `x-api-key` header on outbound requests (A01). |
| `WithTLSConfig(cfg)` | Pins TLS verification with a custom `*tls.Config` (A02). |
| `WithInsecureHTTP()` | Allows `http://` base URLs for local dev only (A02). |
| `WithHTTPClient(client)` | Overrides the HTTP client (test-only; bypasses SSRF protection). |
| `WithLogger(logger)` | Overrides the default `slog.Logger` for structured logging (A09). |

## Logging contract

`slog` is the mandatory structured-logging interface for all code in this
repository. `fmt.Println` / `log.Printf` MUST NOT be used for
security-relevant events.

### Levels

| Level | When to use |
| --- | --- |
| `Info` | Successful request/call completion (access log). |
| `Warn` | Recoverable failure: non-OK upstream status, cart validation failure, unauthenticated request rejected. |
| `Error` | Unexpected failure: request build error, transport error, JSON decode error, recovered panic. |

### Server (`cmd/products-api`) — `requestLogger` middleware

Every request is logged once by the `requestLogger` middleware with:

| Field | Example | Notes |
| --- | --- | --- |
| `method` | `GET` | HTTP method |
| `path` | `/products` | URL path |
| `status` | `200` | Response status code |
| `remote` | `127.0.0.1:54321` | `RemoteAddr` |
| `elapsed_ms` | `3` | Wall-clock latency in ms |

Recovered panics are logged at `Error` with `method`, `path`, `remote`, and
`panic` by the `recoveryMiddleware`.

### Client (`OrdersManager`) — `fetchProducts`

| Event | Level | Fields |
| --- | --- | --- |
| Request completed | `Info` | `url`, `status`, `product_count`, `elapsed` |
| Non-OK upstream status | `Warn` | `url`, `status`, `elapsed` |
| Request build error | `Error` | `base_url`, `error` |
| Transport error | `Error` | `url`, `elapsed`, `error` |
| JSON decode error | `Error` | `url`, `status`, `error` |
| Cart validation failure | `Warn` | `item_count`, `invalid_count`, `details` |

### Conventions

- All field names are `snake_case` string keys (slog convention).
- `elapsed` / `elapsed_ms` are wall-clock durations from request start.
- Never log secrets (API keys, credentials). The `x-api-key` value is never
  emitted; only its presence/absence is implied by the auth outcome.
- New HTTP handlers or outbound HTTP calls MUST follow this contract — see
  [docs/checklists/code-review.md](docs/checklists/code-review.md#4-structured-logging-slog).

## Smoke tests

The smoke suite is black-box HTTP: it runs `hurl --test` against a real server
process. By default the Taskfile boots the local `cmd/products-api` fixture on
`127.0.0.1:18080`; set `BASE_URL` to point at a deployed instance instead.

```sh
task smoke        # run every scenario
task smoke:list   # per-scenario PASS/FAIL summary
task smoke:count  # how many scenarios
```

Prerequisites: `go`, `hurl`, `task`.

## Dantotsu defect analysis

Each fixed OWASP issue has a Dantotsu root-cause analysis report under
`docs/dantotsu/`, following the `_template.md` formalism. These reports document
the problem statement, causal chain, root cause, detection failure, and
eradication strategy for each defect.

| Report | OWASP Category | Issue |
|---|---|---|
| [A01-client-api-key-auth.md](docs/dantotsu/A01-client-api-key-auth.md) | A01 | Client did not authenticate to the server |
| [A04-A10-ssrf-protection.md](docs/dantotsu/A04-A10-ssrf-protection.md) | A04/A10 | Attacker-controllable baseURL targeting internal endpoints |
| [A04-negative-quantity-validation.md](docs/dantotsu/A04-negative-quantity-validation.md) | A04 | Negative cart quantity reducing the total |
| [A05-maxheaderbytes-panic-recovery.md](docs/dantotsu/A05-maxheaderbytes-panic-recovery.md) | A05 | Missing MaxHeaderBytes and panic recovery |
| [A09-structured-logging.md](docs/dantotsu/A09-structured-logging.md) | A09 | No structured logging of requests, errors, or validation failures |
