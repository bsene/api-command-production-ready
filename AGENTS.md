# Repository Guidelines

## Project Structure & Module Organization

- `orders_manager.go`, `product.go` — core `OrdersManager` client and wire types (`Product`, `CartItem`, `CartValidation`, …)
- `orders_manager_test.go` — unit tests using a mocked HTTP transport
- `cmd/products-api/` — local HTTP fixture emulating the products API; the smoke-test target
- `smoke-tests/*.hurl` — black-box QA scenarios run with `hurl`
- `docs/dantotsu/` — Dantotsu defect-analysis reports; `docs/checklists/` — review and hardening checklists
- `infra/` — Pulumi (TypeScript) project deploying a Go Lambda; `infra/lambda/` holds the Go handler

## Build, Test, and Development Commands

- `go test ./...` — run unit tests
- `go vet ./...` — static analysis (also `task smoke:vet`)
- `task smoke` — boot the fixture, run every Hurl scenario (the sign-off gate)
- `task smoke:list` — per-scenario PASS/FAIL summary; `task smoke:count` — scenario count
- `task` — list all tasks
- Infra: `cd infra && npm run build:lambda` (build `dist/lambda.zip`), `npm run preview` / `npm run up` (Pulumi)

## Coding Style & Naming Conventions

- Go: `gofmt`-formatted, standard-library idioms, idiomatic naming (`NewOrdersManager`, `WithAPIKey`)
- `slog` structured logging is mandatory; never use `fmt.Println`/`log.Printf` for security-relevant events. Log field names are `snake_case`; never log secrets
- Model counts/quantities as the `Quantity` type so invalid states are unrepresentable; validate `> 0` at point of use
- Infra TypeScript follows `infra/tsconfig.json`; build via npm scripts

## Testing Guidelines

- Go tests use `TestXxx` naming, table-driven cases, and `httptest`-mocked transports
- Security controls (A01, A02, A04, A10) and the slog contract (A09) must have test coverage
- One `.hurl` file per smoke scenario in `smoke-tests/`; run with `task smoke`
- `WithHTTPClient` bypasses SSRF protection — confine it to `*_test.go` files

## Commit & Pull Request Guidelines

- Conventional Commits: `feat:`, `fix:`, `docs:`, `test:`, `chore:`, `refactor:`; use a scope for infra (`feat(infra):`, `fix(lambda):`)
- Keep commits atomic; explain the *why* in the body
- PRs touching `orders_manager.go`, `cmd/products-api/main.go`, or new HTTP code must pass `docs/checklists/code-review.md`
- New OWASP-relevant fixes: add a Dantotsu report under `docs/dantotsu/` from `_template.md` and link it in the README

## Security & Configuration Tips

- Base URLs default to HTTPS; `WithInsecureHTTP()` is for local dev only
- The SSRF-safe transport is the default — never dial with `http.DefaultTransport`
- Every `http.Server{}` needs timeouts, `MaxHeaderBytes`, and panic-recovery middleware
