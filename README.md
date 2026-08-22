# api-command

Kata: [Préparation de commandes](https://github.com/xnopre/xnopre-katas/blob/master/api_command.md)

`OrdersManager` consumes the fictional products API (`https://products.com`) to
prepare sports-product orders.

## Production smoke tests

After `pulumi up` completes, run the Hurl smoke scenarios in `smoke-tests/prod/`
against the deployed Lambda Function URL:

```sh
export LAMBDA_API_KEY="your-pulumi-secret"
task smoke:prod
```

To see per-scenario results:

```sh
task smoke:prod:list
```

The URL is baked into `Taskfile.yml` as `PROD_URL`; the API key must be supplied
via the `LAMBDA_API_KEY` environment variable (the same Pulumi secret set with
`pulumi config set --secret lambdaApiKey`). These scenarios validate the
production authentication gate (A01) and the availability response contract
without relying on the local fixture.


## Layout

- `lib/orders_manager.ml` — the `Orders_manager` client (list, availability, search, cart validation)
- `lib/cohttp_backend.ml` — the production SSRF-safe HTTP backend (dial-time IP check)
- `lib/product.ml` / `lib/wire.ml` — wire types (`Product`, `Cart_item`, `Cart_validation`, …)
- `lib/test/orders_manager_test.ml` — unit tests (mocked HTTP backend)
- `server/main.exe` — a real HTTP server emulating the products API, used as the smoke-test target
- `infra/catalog/products.json` — the **single shared product catalog** (JSON fixture) served by both the local fixture and the production Lambda layer
- `smoke-tests/*.hurl` — QA smoke scenarios, run with the `hurl` tool against a real server
- `integration/client_smoke.ml` — standalone client integration test driving the real client against the fixture
- `docs/dantotsu/` — Dantotsu defect-analysis reports (added per fix, removed once verified)

## Security

The products API fixture and the `OrdersManager` client include OWASP-aligned
controls. Each control had a Dantotsu root-cause analysis (reports are removed
once their fixes are verified; see the *Dantotsu defect analysis* section).

- **A01 – Broken Access Control**
  - The fixture authenticates every request with an `x-api-key` header
    (`-api-key` flag / `PRODUCTS_API_KEY` env); anonymous calls get `401`.
  - The listen address defaults to loopback and refuses non-loopback binds
    unless `-allow-external` is passed, preventing accidental exposure.
  - The `Orders_manager` client sends `x-api-key` via the `~api_key` option
    when the upstream API requires authentication.

- **A02 – Cryptographic Failures**
  - `Orders_manager.create` rejects plain `http://` base URLs by default; use
    `~allow_insecure_http:true` only for the local dev fixture.
  - The Cohttp backend verifies TLS against the default CA trust store
    (`ca-certs`); it does not pin custom RootCAs or a minimum TLS version.
  - The fixture can serve HTTPS via `-tls-cert` / `-tls-key`, and sets
    `Strict-Transport-Security` over TLS plus baseline defensive headers.

- **A04 – Insecure Design**
  - **SSRF protection**: the base URL host is validated at construction time
    (IP-literal check) and at dial time (DNS resolution + IP range check) to
    prevent requests to cloud metadata endpoints (`169.254.169.254`),
    loopback, private subnets, and link-local addresses.
  - **Negative quantity validation**: `validate_cart` rejects zero or negative
    `Cart_item.quantity` values (`Cart_item_invalid_quantity` reason), preventing
    cart-total manipulation.

- **A05 – Security Misconfiguration**
  - The server sets `ReadHeaderTimeout`, `ReadTimeout`, `WriteTimeout`,
    `IdleTimeout`, and `MaxHeaderBytes` (1 MiB).
  - The `recover` middleware catches exceptions in any handler or middleware, logs
    them, and returns a clean `500` instead of crashing the process.
  - Security headers (`X-Content-Type-Options`, `X-Frame-Options`,
    `Cache-Control`, `Content-Security-Policy`, HSTS over TLS) are set on
    every response.
  - The deployed Lambda Function URL (infra) caps reserved concurrency and
    enforces a ≥32-byte API key to resist brute-force and billing-DoS.

- **A09 – Security Logging and Monitoring Failures**
  - The server logs every request (method, path, status, remote, elapsed) via
    the `Log` module through the `request_logger` middleware.
  - The `Orders_manager` client logs outbound requests (URL, status, count,
    elapsed), upstream errors, and cart validation failures at appropriate levels.

- **A10 – Server-Side Request Forgery (SSRF)**
  - See A04 SSRF protection above — the same countermeasure addresses A10.

## Options reference

| `Orders_manager.create` option | Purpose |
|---|---|
| `~api_key:"…"` | Sets the `x-api-key` header on outbound requests (A01). |
| `~http_client:(module …)` | Injects the HTTP backend (production: `Cohttp_backend`; tests: `Fake_transport`; test-only SSRF bypass). |
| `~allow_insecure_http:true` | Allows `http://` base URLs for local dev only (A02). |
| `~logger` | Injects a `Log.t` for structured logging (A09). |

## Logging contract

`lib/log.ml` (the `Log` module) is the mandatory structured-logging interface
for all code in this repository. Raw `print_endline`/`Printf.printf` MUST NOT
be used for security-relevant events.

### Levels

| Level | When to use |
| --- | --- |
| `Info` | Successful request/call completion (access log). |
| `Warn` | Recoverable failure: non-OK upstream status, cart validation failure, unauthenticated request rejected. |
| `Error` | Unexpected failure: request build error, transport error, JSON decode error, recovered panic. |

### Server (`server/server.ml`) — `request_logger` middleware

Every request is logged once by the `request_logger` middleware with:

| Field | Example | Notes |
| --- | --- | --- |
| `method` | `GET` | HTTP method |
| `path` | `/products` | URL path |
| `status` | `200` | Response status code |
| `remote` | `127.0.0.1:54321` | `RemoteAddr` |
| `elapsed_ms` | `3` | Wall-clock latency in ms |

Recovered panics are logged at `Error` with `method`, `path`, `remote`, and
`panic` by the `recover` middleware.

### Client (`Orders_manager`) — `fetch_products`

| Event | Level | Fields |
| --- | --- | --- |
| Request completed | `Info` | `url`, `status`, `product_count`, `elapsed` |
| Non-OK upstream status | `Warn` | `url`, `status`, `elapsed` |
| Request build error | `Error` | `base_url`, `error` |
| Transport error | `Error` | `url`, `elapsed`, `error` |
| JSON decode error | `Error` | `url`, `status`, `error` |
| Cart validation failure | `Warn` | `item_count`, `invalid_count`, `details` |

### Conventions

- All field names are `snake_case` string keys (the `Log` module's key-value pairs).
- `elapsed` / `elapsed_ms` are wall-clock durations from request start.
- Never log secrets (API keys, credentials). The `x-api-key` value is never
  emitted; only its presence/absence is implied by the auth outcome.
- New HTTP handlers or outbound HTTP calls MUST follow this contract — see
  [docs/checklists/code-review.md](docs/checklists/code-review.md#4-structured-logging-slog).

## Smoke tests

The smoke suite is black-box HTTP: it runs `hurl --test` against a real server
process, plus a standalone OCaml client integration test that drives the real
`Orders_manager` client (via the SSRF-safe `Cohttp_backend`) against the same
fixture. By default the Taskfile boots the local `server/main.exe` fixture on
`127.0.0.1:18080`; set `BASE_URL` to point at a deployed instance instead.

```sh
task smoke            # run every Hurl scenario + the client integration test
task smoke:list       # per-scenario PASS/FAIL summary
task smoke:count      # how many scenarios
task integration:client  # run only the OCaml client integration test (fixture must be running)
```

The client integration test (`integration/client_smoke.exe`) exercises the
client↔server auth contract end-to-end (A01): a manager with the wrong
`x-api-key` must fail and one with the right key must succeed, closing the gap
the Hurl (server-only) and Alcotest (mock-only) suites left open.

Prerequisites: `go`, `hurl`, `task`.

## Dantotsu defect analysis

Every OWASP issue fixed in this kata had a Dantotsu root-cause analysis report
under `docs/dantotsu/` (following the `_template.md` formalism). Each report was
removed once its countermeasure was verified in code and tests; the security
controls themselves remain in place (documented in the OWASP controls above).
The `_template.md` formalism is retained for any future report.
