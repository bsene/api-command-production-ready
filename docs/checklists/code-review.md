# Code-Review Checklist

> Dantotsu eradication — cross-cutting prevention strategies for **A04
> (Insecure Design)**, **A05 (Security Misconfiguration)**, and **A09
> (Security Logging & Monitoring Failures)**.
>
> Run through this checklist for every PR that touches
> `lib/orders_manager.ml`, `server/main.ml`, or adds a new HTTP
> client/server.

## 1. Numeric fields that represent a count or quantity

- [ ] Any `int` field representing a count, quantity, or amount MUST be
      validated for `> 0` at the point of use — or, preferably, modeled as the
      `Quantity` type so the invalid state is unrepresentable.
- [ ] Externally-sourced quantities MUST go through `NewQuantity(n)`, which
      rejects `n <= 0`. Literal construction (`Quantity(n)`) is only
      acceptable for trusted compile-time constants.
- [ ] No business-logic computation (`Price * Quantity`, stock comparison,
      total accumulation) may run before the quantity sign has been checked.
      `CartItem.Validate()` is the canonical guard; `ValidateCart` calls it
      before any stock or price work.

## 2. `http.Server{}` instances

- [ ] Every new `http.Server{}` satisfies all items in
      [server-hardening.md](server-hardening.md) — in particular
      `MaxHeaderBytes` is non-zero and the handler chain includes a
      panic-recovery middleware.
- [ ] No handler is registered on a bare `ServeMux` without going through the
      middleware `chain` (recovery + logging + auth).

## 3. Outbound HTTP clients (`OrdersManager` and any future client)

- [ ] The SSRF-safe transport (`Cohttp_backend`, dial-time `Ssrf.check_ssrf_ip`
      on every resolved IP) is the default. Any code that bypasses it via the
      `~http_client:` labelled arg MUST be confined to `lib/test/**` or
      `integration/**` (the integration smoke uses the *real* `Cohttp_backend`,
      not a bypass). The `task smoke:vet` `~http_client:` confinement assertion
      enforces this; locally, reviewers reject `~http_client:` outside those
      paths.
- [ ] Any new outbound HTTP client in this codebase reuses
      `Cohttp_backend` or `Ssrf.check_ssrf_ip` — never dials with the OS default
      resolver/transport.
- [ ] Authentication credentials are sent on every outbound request that
      targets an authenticated upstream (`x-api-key` via `with_api_key`).

## 4. Structured logging (`slog`)

- [ ] Every new HTTP handler logs at **Info** (success) and **Error/Warn**
      (failure) with structured fields via `slog` — never `fmt.Println` /
      `log.Printf` for security-relevant events.
- [ ] Every new outbound HTTP call logs the URL, status, elapsed time, and
      error (if any). `OrdersManager.fetchProducts` is the reference.
- [ ] Cart/validation failures are logged at **Warn** with per-item details.
- [ ] See the [logging contract](../../README.md#logging-contract) in the
      README for the full field conventions.

## 5. Reports

- [ ] If a new OWASP-relevant defect is found and fixed, add a Dantotsu report
      under `docs/dantotsu/` using `_template.md` and link it from the README
      defect table.

## 6. Public endpoints (AWS / infra)

- [ ] Any new public endpoint (Lambda Function URL, API Gateway, ALB, …) MUST
      bound resource consumption — reserved concurrency, a rate limit, or WAF —
      and MUST enforce a minimum API-key strength (≥32 bytes / 256-bit) at
      deploy time, failing closed at runtime if the key is missing or too short.
- [ ] Any handler serving a public endpoint reuses the per-IP rate limiter
      (`lambda/rate_limit.ml`) or an equivalent fixed-window cap, checked
      **before** auth (all-requests policy), returning `429` + `Retry-After` on
      overflow. The local loopback fixture (`server/`) is exempt — it is not
      internet-facing and smoke tests burst. Document the per-instance caveat
      (in-memory, resets on cold start, not shared across parallel instances).

