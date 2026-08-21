# Repository Guidelines

## Project Structure & Module Organization

- `lib/orders_manager.ml`, `lib/product.ml`, `lib/wire.ml` — core `Orders_manager` client and wire types (`Product`, `Cart_item`, `Cart_validation`, …)
- `lib/cohttp_backend.ml` — the production SSRF-safe HTTP backend (dial-time IP check via a custom `Resolver_lwt.t`)
- `lib/test/orders_manager_test.ml` — unit tests using a mocked HTTP backend
- `server/main.ml` — local HTTP fixture emulating the products API; the smoke-test target
- `smoke-tests/*.hurl` — black-box QA scenarios run with `hurl`
- `integration/client_smoke.ml` — standalone client integration test driving the real client against the fixture
- `docs/dantotsu/` — Dantotsu defect-analysis reports; `docs/checklists/` — review and hardening checklists
- `infra/` — Pulumi (TypeScript) project deploying an OCaml Lambda; `lambda/` holds the OCaml handler (built via `Dockerfile.lambda`)

## Build, Test, and Development Commands

- `dune build` — build the OCaml workspace (lib + server + lambda)
- `dune runtest` — run all Alcotest suites (also `task smoke:vet`)
- `task smoke` — boot the fixture, run every Hurl scenario + the client smoke (the sign-off gate)
- `task smoke:client` — run only the OCaml client smoke against a running fixture
- `task smoke:list` — per-scenario PASS/FAIL summary; `task smoke:count` — scenario count
- `task` — list all tasks
- Infra: `cd infra && npm run build:lambda` (build `dist/lambda.zip`), `npm run preview` / `npm run up` (Pulumi)

## Coding Style & Naming Conventions

- OCaml: `ocamlformat`-clean, idiomatic naming (`Orders_manager.create`, `with_api_key`), follows `dune-project`
- `lib/log.ml` (the `Log` module) structured logging is mandatory; never print to stdout directly for security-relevant events. Log field names are `snake_case`; never log secrets
- Model counts/quantities as the `quantity` type in `lib/product.ml` so invalid states are unrepresentable; validate `> 0` at point of use
- Infra TypeScript follows `infra/tsconfig.json`; build via npm scripts

## Testing Guidelines

- OCaml tests are Alcotest suites with a mocked HTTP backend in `lib/test/orders_manager_test.ml`
- Security controls (A01, A02, A04, A10) and the `Log` module contract (A09) must have test coverage
- One `.hurl` file per smoke scenario in `smoke-tests/`; run with `task smoke`
- The SSRF-bypass hook (`with_http_client` / insecure transport) is test-only — confine it to `lib/test/`

## Commit & Pull Request Guidelines

- Conventional Commits: `feat:`, `fix:`, `docs:`, `test:`, `chore:`, `refactor:`; use a scope for infra (`feat(infra):`, `fix(lambda):`)
- Keep commits atomic; explain the *why* in the body
- PRs touching `lib/orders_manager.ml`, `server/main.ml`, or new HTTP code must pass `docs/checklists/code-review.md`
- New OWASP-relevant fixes: add a Dantotsu report under `docs/dantotsu/` from `_template.md` and link it in the README

## Security & Configuration Tips

- Base URLs default to HTTPS; `with_insecure_http` is for local dev only
- The SSRF-safe transport is the default — never dial with the OS default transport
- Every HTTP server (`server/server.ml`) needs timeouts, a max header size, and panic-recovery middleware
