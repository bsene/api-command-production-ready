# Remove all Go — OCaml becomes the sole implementation

## Context

The project was translated from Go to OCaml (mikado). Two Go code paths remain:

1. **Go Lambda** (`infra/lambda/`) — ported to OCaml `lambda/` (commits L3a–L3d), but
   the deploy path still builds and ships Go: `infra/package.json build:lambda` runs
   `go build`, and docs/comments still say "Go Lambda".
2. **Root Go module** (`go.mod`, `orders_manager.go`, `product.go`,
   `orders_manager_test.go`, `cmd/products-api/`) — ported to OCaml `lib/`
   (`orders_manager.ml`, `product.ml`, `wire.ml`, `ssrf.ml`, `log.ml`) and `server/`
   (`server.ml`, `cli.ml`, `catalog.ml`, `main.ml`). The Taskfile already builds
   `dune build server/main.exe` and tests via `dune runtest` — no Go is invoked.

OCaml parity is complete: `lib/test/orders_manager_test.ml` covers the same cases as
`orders_manager_test.go`; `server/test/` covers the products-api; `lambda/test/`
covers the handler. Removing Go loses no build or test coverage.

Goal: delete both Go code paths, wire the OCaml Docker cross-compile into the
deploy, and update every doc/comment reference. After this, `go` is no longer a
project prerequisite and no `.go` file remains in the tree.

## A. Deletions

Remove (tracked):
- `infra/lambda/go.mod`, `infra/lambda/go.sum`, `infra/lambda/main.go`,
  `infra/lambda/main_test.go` (whole `infra/lambda/` dir; also untracked
  `infra/lambda/lambda` build artifact).
- `go.mod` (root; no `go.sum` — stdlib only, no third-party deps).
- `orders_manager.go`, `orders_manager_test.go`, `product.go` (root).
- `cmd/products-api/` entire dir (`main.go`, `main_test.go`, `server_test.go`).

Safe: root `go.mod` declares module `bsene/api-command-kata` with zero `require`
blocks; nothing imports it outside the deleted set. `cmd/products-api` is not
built or invoked by the Taskfile (smoke uses `dune build server/main.exe`).

## B. Rewire the Lambda build to OCaml

### B1. `infra/package.json` — `build:lambda`

`Dockerfile.lambda` (repo root) already cross-compiles the OCaml `bootstrap` to
`linux/arm64` into a scratch carrier; its header says the artifact is extracted
via `docker create` + `docker cp`, but the script was never written. Write it:

```sh
docker buildx build --platform linux/arm64 --load \
  -f ../Dockerfile.lambda -t api-command-lambda:builder .. \
  && cid=$(docker create api-command-lambda:builder) \
  && mkdir -p dist \
  && docker cp "$cid":/bootstrap dist/bootstrap \
  && docker rm "$cid" >/dev/null \
  && (cd dist && rm -f lambda.zip && zip -q lambda.zip bootstrap) \
  && echo "built dist/lambda.zip"
```

`--load` puts the arm64 image in the local daemon; `docker create` + `docker cp`
extract `bootstrap` without running the foreign-arch image (native on Apple
Silicon, emulated on amd64 via buildx). `build`, `preview`, `up`, `build:layer`,
`clean:lambda` stay — they chain through `build:lambda`. Update `description`:
`"custom Go Lambda"` → `"custom OCaml Lambda"`.

### B2. `infra/src/index.ts` — comments only (no resource logic change)

The program only points at `dist/lambda.zip`. Update comments:
- L29 "constant-time comparison in Go" → "in OCaml".
- L87 banner `Custom Go Lambda` → `Custom OCaml Lambda`.
- L89–91 "Go binary … GOOS=linux GOARCH=arm64" → "OCaml binary, cross-compiled
  via `Dockerfile.lambda` (linux/arm64)".
- L105, L160 `see infra/lambda/main.go` → `see lambda/main.ml`.

### B3. `Taskfile.yml` — `deploy:build` summary (L247–250)

"compiles the Go Lambda handler (GOOS=linux GOARCH=arm64) into dist/bootstrap" →
"cross-compiles the OCaml Lambda handler to linux/arm64 via `Dockerfile.lambda`
(Docker buildx), extracts `bootstrap`, zips it to `dist/lambda.zip`". Add
Docker/buildx to the prereq note. `deploy` summary (L233) is language-neutral —
leave. No other Taskfile change needed (smoke already dune-only).

## C. Doc updates — Go references → OCaml

### C1. `infra/README.md`
- L1 title, L5–6 intro: `Go Lambda` → `OCaml Lambda`.
- L12 prereq: drop `Go >= 1.21`; add `Docker with buildx`.
- L40–57 "The custom Go Lambda" section: handler is the OCaml library at
  repo-root `lambda/`; entry `bootstrap` built by `Dockerfile.lambda`; runtime
  loop hand-rolled in `lambda/runtime.ml` (no `aws-lambda-go`).
- L59–65 Build: `npm run build:lambda` runs the Docker cross-compile (needs
  Docker, not Go).
- L76–83 Runtime details: `aws-lambda-go` → hand-rolled Runtime API
  (`lambda/runtime.ml`); keep `provided.al2023`, `arm64`, `handler: bootstrap`.
- L90, L98, L164–166, L189–191: `cmd/products-api` → `server/main.exe`; `lambda/main.go`
  → `lambda/main.ml`.

### C2. `AGENTS.md` (root) — rewrite Go sections to OCaml
- L5–7: `orders_manager.go`/`product.go`/`orders_manager_test.go`/`cmd/products-api/`
  → `lib/orders_manager.ml`, `lib/product.ml`, `lib/wire.ml`, `lib/test/orders_manager_test.ml`,
  `server/main.ml`.
- L8: `deploying a Go Lambda; infra/lambda/ holds the Go handler` → `deploying an
  OCaml Lambda; lambda/ holds the OCaml handler (built via Dockerfile.lambda)`.
- L14–15: `go test ./...` / `go vet ./...` → `dune runtest` (and `dune build`).
- L23: Go `gofmt`/`NewOrdersManager`/`WithAPIKey` style line → OCaml equivalent
  (`Orders_manager.create`, `with_api_key`, follow `dune-project`).
- L24: `slog` mandatory → `lib/log.ml` (Log module) mandatory; never log secrets.
- L25: `Quantity` type → `lib/product.ml` `quantity`.
- L30: Go `TestXxx`/`httptest` → Alcotest suites, mocked HTTP backend in
  `lib/test/orders_manager_test.ml`.
- L33: `WithHTTPClient` bypasses SSRF — confine to `*_test.go` → OCaml equivalent
  (test-only SSRF-bypass hook in `lib/test/`).
- L39: `orders_manager.go`, `cmd/products-api/main.go` → `lib/orders_manager.ml`,
  `server/main.ml`.
- L46: `http.Server{}` timeouts/`MaxHeaderBytes`/panic-recovery →
  `server/server.ml` equivalent config.

### C3. `README.md` (root)
- L33–36: `orders_manager.go`/`product.go`/`orders_manager_test.go`/`cmd/products-api`
  → `lib/orders_manager.ml`, `lib/product.ml`/`lib/wire.ml`,
  `lib/test/orders_manager_test.ml`, `server/main.exe`.
- L121, L159: `cmd/products-api` → `server/server.ml` / `server/main.exe`.

### C4. Checklists
- `docs/checklists/server-hardening.md:55`: `cmd/products-api/main.go` reference →
  `server/server.ml` / `server/main.ml`.
- `docs/checklists/code-review.md:8`: `orders_manager.go`,
  `cmd/products-api/main.go` → `lib/orders_manager.ml`, `server/main.ml`.

### C5. Dantotsu reports (`docs/dantotsu/`)

Fully implemented reports (A01, A04-lambda-input-validation,
A05-maxheaderbytes-panic-recovery, A09) were removed once their fixes were
verified in code and tests. The remaining active reports need path/identifier
updates where they still reference Go artifacts:

- `A04-A10-ssrf-protection.md:23,173` → `lib/ssrf.ml`, `lib/orders_manager.ml`.
- `A04-negative-quantity-validation.md:22,121` → `lib/orders_manager.ml`
  `validate_cart`, `lib/product.ml`.
- `A05-rate-limiting.md:157` → `server/`.

No full code-block rewrites remain for the deleted reports.

### C6. `SECURITY-REVIEW-LAMBDA.md:77`
"cd infra/lambda && go test ./... runs no tests; the handler has no in-tree
tests" → infra/lambda is gone; the OCaml handler has tests (`lambda/test/lambda_test.ml`,
`lambda/test/loop_test.ml` via `dune runtest`). Rewrite to reflect that.

## D. gitignore cleanup

- `infra/.gitignore`: remove the dead Go lines:
  ```
  # Go build artifact from manual `go build` in lambda/
  lambda/lambda
  ```
  Keep `node_modules/`, `bin/`, `.pulumi/`, `dist/`.
- Root `.gitignore`: no Go-binary entries exist — no change.
- (Untracked) `rm infra/dist/bootstrap.go-backup`, `infra/dist/lambda.zip.go-backup`
  — gitignored leftovers from the in-progress swap; clear so a fresh
  `npm run build:lambda` is unambiguous.

## E. Out of scope / untouched

- `Dockerfile.lambda` (already correct), `lambda/` + `lib/` + `server/` OCaml
  sources, `infra/src/index.ts` resource logic.
- `.agents/skills/golang/` + `skills-lock.json` `golang` entry — agent skill docs,
  not project code. Keep.

## Files

- **Delete:** `infra/lambda/` (4 files), `go.mod`, `orders_manager.go`,
  `orders_manager_test.go`, `product.go`, `cmd/products-api/` (3 files).
- **Edit:** `infra/package.json`, `infra/src/index.ts`, `infra/README.md`,
  `Taskfile.yml`, `AGENTS.md`, `README.md`, `SECURITY-REVIEW-LAMBDA.md`,
  `docs/checklists/server-hardening.md`, `docs/checklists/code-review.md`,
  `docs/dantotsu/A04-A10-ssrf-protection.md`,
  `A04-negative-quantity-validation.md`, `A05-rate-limiting.md`,
  `infra/.gitignore`.

## Verification

1. `go` no longer referenced: `/usr/bin/grep -rliE 'go\.mod|aws-lambda-go|GOOS|gofmt|go test|go vet|orders_manager\.go|product\.go|cmd/products-api|main\.go' . --exclude-dir=node_modules --exclude-dir=_build --exclude-dir=.git --exclude-dir=.agents` returns only the `.agents/skills/golang` skill docs (intentionally kept).
2. No `.go` files: `/usr/bin/find . -name '*.go' -not -path './.agents/*' -not -path './_build/*'` returns nothing.
3. `dune build` (root) → builds `apicommand`, `server_lib`/`products-api`, `lambda_lib`/`bootstrap`.
4. `dune runtest` (root) → all Alcotest suites pass (`lib/test`, `server/test`, `lambda/test`).
5. `cd infra && npm run build:lambda` → succeeds; `file infra/dist/bootstrap` → `ELF 64-bit LSB executable, ARM aarch64, dynamically linked` (OCaml glibc binary, ~20 MB — distinct from the old ~7 MB static Go binary).
6. `npm run build` → `dist/lambda.zip` + `dist/catalog-layer.zip`.
7. `task smoke:vet` → `dune runtest` passes.
8. `task smoke` → boots `dune build server/main.exe` fixture, Hurl scenarios pass (no Go server involved).
9. `task deploy:preview` (with `PULUMI_CONFIG_PASSPHRASE` + `AWS_PROFILE`) → `pulumi preview` reflects the rebuilt OCaml zip.

## Refactoring scan (post-execution)

Per the rule-of-three workflow, scan the diff after execution for reuse /
simplification / altitude opportunities and report as Blockers / Warnings /
Suggestions. The doc path-swaps are mechanical; flag any prose that repeats the
same Go→OCaml explanation three times as a candidate to consolidate.