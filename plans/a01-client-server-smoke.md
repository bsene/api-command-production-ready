# A01 — End-to-end client↔server smoke test

## Context

The A01 Dantotsu report (`docs/dantotsu/A01-client-api-key-auth.md`) identified a
detection gap: the Hurl smoke suite exercises the **server** directly (black-box
HTTP), and the Alcotest suite exercises the **client** against a `Fake_transport`
mock — but nothing exercises the real OCaml `Orders_manager` client against the
live fixture. The report's prevention strategy explicitly calls for:

> "Add a CI check (or smoke-test scenario) that boots the authenticated fixture
> and calls `OrdersManager` against it end-to-end, failing if any method
> returns 401."

The blocker is that the client's production HTTP backend does not exist yet:
`Orders_manager` takes an injectable `HTTP_BACKEND`, but the only concrete
implementations are `Stub_backend` (hard-errors if called) and the test-only
`Fake_transport`. The real `Cohttp_backend` was deferred to "G2" (see
`lib/orders_manager.mli`). `cohttp-lwt-unix` is already a project dependency
(used by `lambda/runtime.ml`), so the library is available.

## Decisions (confirmed)

1. **Form** — a standalone `integration/client_smoke.exe` run by a new `integration:client`
   Taskfile task, folded into `task smoke` (mirrors the Hurl pattern; keeps the
   live-server test out of the mock-only `dune runtest`).
2. **SSRF scope** — full SSRF-safe transport: resolve hostnames, check every
   resolved IP against `Ssrf.check_ssrf_ip`, refuse to dial unsafe IPs. This is
   the production backend AGENTS.md mandates ("never dial with the OS default
   transport"), not a smoke-only stub.
3. **Location** — new module in `lib/` (adds `cohttp-lwt-unix` to `apicommand`).

## Approach

### 1. `lib/cohttp_backend.ml` / `.mli` (new) — real SSRF-safe backend

Implements `Orders_manager.HTTP_BACKEND` over `cohttp-lwt-unix`, with the
SSRF-safe dialing the `.mli` defers to "G2".

**SSRF-safe transport** — the crux. `cohttp-lwt-unix` resolves hostnames via
`Conduit_lwt_unix`'s default `Resolver_lwt_unix.system` (the OS resolver), which
would dial whatever IP DNS returns. We replace it with a custom
`Resolver_lwt.t` whose `rewrite_fn` (`svc -> Uri.t -> Conduit.endp Lwt.t`):

1. Extract `host` from `Uri.host uri` and `port` from `svc.port`.
2. Resolve `host` → IPs via `Lwt_unix.getaddrinfo`.
3. Map each `Lwt_unix.ADDR_INET (inet, _)` to `Ipaddr.t` via
   `Ipaddr_unix.of_inet_addr`.
4. Run `Ssrf.check_ssrf_ip ip allow_local_dev` on **every** resolved IP; if any
   is unsafe, fail (DNS-rebinding-safe — a mixed answer must not be dialed).
5. Return `` `TCP (`IP ip, `Port port) `` for `http`, or
   `` `TLS (`Hostname host, `IP ip, `Port port) `` for `https` (from `svc.tls`),
   for the first safe IP.

The backend is built by `Cohttp_backend.make ~allow_local_dev ()` returning
`(module Orders_manager.HTTP_BACKEND)`. It constructs the resolver, then
`Cohttp_lwt_unix.Net.init ~resolver ()` to get a `ctx`, and `request` calls
`Cohttp_lwt_unix.Client.get ~ctx ~headers uri` (the client only ever issues GET
today; `method_` is honored via `Client.call` if we want generality). The whole
call is wrapped in `Lwt.catch` → `Error (Printexc.to_string exn)` on transport
failure, matching the `HTTP_BACKEND` error contract.

`response` is `{ status : int; body : string }`; `status`/`body` are trivial
accessors.

**Flag threading** — `allow_local_dev` is baked into the backend at construction
(the `HTTP_BACKEND.request` signature has no room for it). The caller passes the
same value to `Cohttp_backend.make ~allow_local_dev` and
`Orders_manager.create ~allow_insecure_http` — for the local fixture both are
`true`.

### 2. `lib/dune` — widen `apicommand` deps

Add to `libraries`: `cohttp-lwt-unix`, `conduit-lwt-unix`, `ipaddr.unix`
(`lwt.unix` is already present for `Lwt_unix.getaddrinfo`). `conduit-lwt-unix`
and `ipaddr.unix` are needed because the code references `Conduit_lwt_unix` /
`Resolver_lwt` / `Ipaddr_unix` directly.

**No openssl regression** — `conduit-lwt-unix` lists `lwt_ssl`/`ssl` only as
`{with-test}` deps; TLS is the pure-OCaml `ca-certs`/`tls` stack. `cohttp-lwt-unix`
is already linked into the Lambda bootstrap via `lambda_lib`, so `apicommand`
gains no new transitive dep the bootstrap doesn't already carry. Verify with
`dune build` + the Docker cross-compile still succeeding.

### 3. `integration/client_smoke.ml` + `integration/dune` (new) — the smoke executable

A standalone executable (not an Alcotest suite) that:

1. Reads `--base-url` (default `http://127.0.0.1:18080`) and `--api-key`
   (default `smoke-test-key`) from argv (or env).
2. Builds `Cohttp_backend.make ~allow_local_dev:true ()`.
3. `Orders_manager.create ~base_url ~http_client:backend ~allow_insecure_http:true
   ~api_key ()`.
4. Drives the public methods and asserts against the known 16-product catalog
   (`infra/catalog/products.json`):
   - `all_descriptions` → 16 entries, sorted; spot-check first/last.
   - `available_descriptions` → 14 (refs 3 and 15 have `stock = 0`).
   - `is_available 1` → `true`; `is_available 3` → `false`.
   - `search "tennis"` → refs 2, 3, 14 (balle/raquette/filet de tennis).
   - `validate_cart` valid → correct total; out-of-stock → `Invalid_cart` code 422.
   - **A01 regression**: a manager with the *wrong* api key must fail (401), and
     one with the *right* key must succeed — this is the exact gap the report
     flagged.
5. Prints a PASS/FAIL line per assertion and exits non-zero on any failure.

Plain assertions + `exit 1` (smoke philosophy: fail fast, clear output), not
Alcotest — this is a live-server gate, not a unit test.

`integration/dune`:
```
(executable
 (name client_smoke)
 (libraries apicommand lwt.unix))
```

### 4. `Taskfile.yml` — wire `integration:client` into the gate

New task:
```yaml
integration:client:
  desc: Run the OCaml Orders_manager client against the live fixture.
  cmds:
    - cmd: |
        set -euo pipefail
        dune build integration/client_smoke.exe
        base_url="${BASE_URL:-http://127.0.0.1:{{.PORT}}}"
        _build/default/integration/client_smoke.exe --base-url "$base_url" --api-key "{{.API_KEY}}"
```

Fold into `smoke` (after `task smoke:run`):
```yaml
smoke:
  cmds:
    - cmd: |
        set -euo pipefail
        task smoke:server:start
        trap 'task smoke:server:stop >/dev/null 2>&1 || true' EXIT
        task smoke:run
        task integration:client
```

`integration:client` reuses the already-booted fixture (no second boot). When
`BASE_URL` is set, `smoke:server:start` is a no-op and the client targets the
external server — same semantics as the Hurl path.

### 5. Docs

- `README.md` — add the client smoke path to the "Smoke tests" section; note the
  client↔server auth contract is now exercised end-to-end.
- `AGENTS.md` — mention `lib/cohttp_backend.ml` as the production backend and
  `integration/client_smoke.exe` as the client-side smoke gate.
- `docs/dantotsu/A01-client-api-key-auth.md` — mark the "Prevention Strategy"
  item as implemented (link the new smoke task).

## Files

- **New:** `lib/cohttp_backend.ml`, `lib/cohttp_backend.mli`,
  `integration/client_smoke.ml`, `integration/dune`.
- **Edit:** `lib/dune`, `Taskfile.yml`, `README.md`, `AGENTS.md`,
  `docs/dantotsu/A01-client-api-key-auth.md`.

## Verification

1. `dune build` — `apicommand` now links `cohttp-lwt-unix`; no openssl pulled in.
2. `dune runtest` — existing Alcotest suites still pass (no behavior change to
   the mock-tested client logic).
3. `task integration:client` — boots the fixture, runs the client, exits 0.
4. `task smoke` — Hurl scenarios **and** the client smoke both pass (the gate).
5. `task smoke:list` — still lists Hurl scenarios; `integration:client` is a separate
   gate (documented).
6. `cd infra && npm run build:lambda` — Docker cross-compile still succeeds
   (confirms `apicommand`'s new deps don't break the bootstrap).
7. Negative check: run `integration:client` with a wrong `--api-key` → exits non-zero
   (proves the A01 regression is actually caught).

## Out of scope

- TLS/`https` end-to-end (the fixture is plain HTTP on loopback; the `TLS`
  endpoint branch is implemented but only exercised by the unit-level SSRF
  checks, not a live TLS server).
- `method_` generality beyond GET (the client only issues GET today).
- Folding the client smoke into `dune runtest` (deliberately kept separate).
