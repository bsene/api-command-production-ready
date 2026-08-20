# Server-Hardening Checklist

> Dantotsu eradication — prevention strategy for **A05 (Security Misconfiguration)**.
>
> Every `http.Server{}` in this codebase MUST satisfy all items below before
> merge. The checklist is referenced by `docs/dantotsu/A05-maxheaderbytes-panic-recovery.md`.

## `http.Server` configuration

Verify each field is set explicitly — never rely on the zero value for a
security-relevant field.

| Field | Required value / rule | Why |
| --- | --- | --- |
| `ReadHeaderTimeout` | Non-zero (≤ 5 s for this project) | Slowloris defence (Go issue G114) |
| `ReadTimeout` | Non-zero (≤ 10 s) | Bounds slow-body reads |
| `WriteTimeout` | Non-zero (≤ 10 s) | Bounds slow clients / stuck handlers |
| `IdleTimeout` | Non-zero (≤ 60 s) | Reclaims idle keep-alive conns |
| `MaxHeaderBytes` | Non-zero (1 << 20 = 1 MB) | Prevents memory exhaustion from oversized headers (A05) |
| `Handler` | Wrapped in a middleware `chain` that includes recovery | See handler-chain section |

## Handler chain

Every handler chain MUST include, in order (outermost first):

1. **Request logger** — structured access log (method, path, status, remote, elapsed). *(A09)*
2. **Panic recovery** — `recover()` from any downstream panic, log it with a
   stack trace, return a clean `500` instead of crashing the process. *(A05)*
3. **Security headers** — `X-Content-Type-Options: nosniff`, `X-Frame-Options:
   DENY`, `Cache-Control: no-store`, `Content-Security-Policy: default-src
   'none'`, HSTS over TLS. *(A02/A05)*
4. **Authentication** — reject unauthenticated requests before the business
   handler runs. *(A01)*

## Bind address

- Default to a loopback address (`127.0.0.1:…`).
- Refuse non-loopback binds unless the caller explicitly opts in
  (`-allow-external`). *(A01)*

## TLS

- Prefer HTTPS in production (`ListenAndServeTLS` with `-tls-cert` / `-tls-key`).
- If exactly one of cert/key is set, fail fast (refuse to start in a
  half-configured state).

## Verification

- The smoke suite (`task smoke`) boots the real binary and asserts
  authentication, status codes, and headers end-to-end.
- Add a Hurl scenario for any new endpoint.

## Reference implementation

`server/server.ml` (wired by `server/main.ml`) is the reference: it satisfies every item above and
should be used as the template for any future HTTP server in this codebase.
