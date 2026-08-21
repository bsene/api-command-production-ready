# Plan — Add vegeta load-testing scenarios (Lambda Function URL only)

## Context

Repo has OCaml Lambda deployed via Pulumi behind a public Function URL (`infra/src/index.ts`). Existing QA is functional only: Hurl smoke scenarios (`smoke-tests/`, `smoke-tests/prod/`) run via `task smoke` / `task smoke:prod`. No load/stress/perf testing exists anywhere. We add vegeta-based load scenarios targeting **only** the deployed Lambda Function URL — never the local Dream fixture (`server/`). Goal: measure latency/throughput under sustained load and validate the `reservedConcurrentExecutions=5` DoS guard throttles with HTTP 429.

Endpoint contract (from `lambda/lambda_handler.ml` + smoke tests):
- `GET /products` → 200, JSON array of 16 catalog products (key `prix`).
- `POST /` (any non-`products` path) → 200 `{ok,ref,message}`; body `{"ref","description","stock","price"}`. Validation: missing body 400, bad JSON 400, description>1024B 400, price<0 400, ref<0 400.
- Auth: `x-api-key` header (constant-time compare); missing → 401.
- `reservedConcurrency=5` (configurable via Pulumi `reservedConcurrency`); above 5 concurrent → AWS throttles Function URL with 429 (throttled invocations do not bill).

## Design decisions

- **Target format: vegeta HTTP plaintext targets.** Human-readable, mirrors Hurl scenarios, supports headers + `@/path/to/body.json` file bodies (verified against vegeta README; inline bodies unsupported). Multiple targets in one file separated by **blank lines**.
- **Secret injection: committed `.http.tmpl` templates + `envsubst` at runtime.** Placeholders `$LOAD_URL`, `$LAMBDA_API_KEY`, `$REPO_ROOT`. Rendered into gitignored `load-tests/results/.gen/`. Key never committed. `envsubst` avoids sed-escaping hazards.
- **`LOAD_URL` defaults to `PROD_URL`** (Taskfile var). Local fixture excluded: tasks never reference `server/`, `BASE_URL`, or `PORT`.
- **`load` umbrella excludes spike/throttle** — primary self-DoS guardrail. Safe suite = baseline + availability + soak. Spike/throttle run explicitly.
- **Throttle scenario EXPECTS 429** — validates DoS guard. 0% 429 = guard inactive → investigate.

## Directory layout (new)

```
load-tests/
  README.md                       # install, run, read results, safety/cost, optional reservedConcurrency bump
  targets/
    get-products.http.tmpl        # GET /products (baseline, spike, throttle)
    post-availability.http.tmpl   # POST / (availability)
    soak-mixed.http.tmpl          # GET /products + POST / mix (soak)
    bodies/
      availability.json           # POST body (no secrets)
  results/                        # gitignored — gob, text report, HTML plot, .gen/
```

## Target templates (exact contents)

`load-tests/targets/get-products.http.tmpl`:
```
GET $LOAD_URL/products
x-api-key: $LAMBDA_API_KEY
```

`load-tests/targets/post-availability.http.tmpl`:
```
POST $LOAD_URL
x-api-key: $LAMBDA_API_KEY
Content-Type: application/json
@$REPO_ROOT/load-tests/targets/bodies/availability.json
```

`load-tests/targets/soak-mixed.http.tmpl` (blank line separates targets):
```
GET $LOAD_URL/products
x-api-key: $LAMBDA_API_KEY

POST $LOAD_URL
x-api-key: $LAMBDA_API_KEY
Content-Type: application/json
@$REPO_ROOT/load-tests/targets/bodies/availability.json
```

`load-tests/targets/bodies/availability.json`:
```json
{"ref":1,"description":"load test availability probe","stock":3,"price":1.5}
```

## Scenarios

In-flight ≈ rate × p50 latency; cap=5.

| Scenario | Target | Rate | Dur | Workers | Reqs | Expect |
|---|---|---|---|---|---|---|
| baseline | get-products | 1 | 10s | 1 | 10 | 100% 200 |
| availability | post-availability | 1 | 10s | 1 | 10 | 100% 200 |
| soak | soak-mixed | 2 | 120s | 2 | 240 | ~100% 200 (under cap) |
| spike | get-products | 20 | 5s | 5 | 100 | mostly 200 |
| throttle | get-products | 1000 | 3s | 100 | 3000 | large 429 fraction (guard active) |

Each scenario:
```bash
vegeta attack -targets=<gen>.http -rate=N -duration=Ds -workers=W > results/<name>.bin
vegeta report -type=text < results/<name>.bin | tee results/<name>.txt
vegeta plot -title="<name>" < results/<name>.bin > results/<name>.html
```

## Taskfile.yml changes

File: `/Users/birrame.sene/workspace/prototypes/api-command/Taskfile.yml`

Add to `vars:` block (after line 49, `INFRA_DIR`):
```yaml
  # ── Load testing (vegeta) — targets ONLY the Lambda Function URL ──
  LOAD_DIR: load-tests
  LOAD_URL: "{{.PROD_URL}}"
  LOAD_RESULTS: load-tests/results
  LOAD_GEN: load-tests/results/.gen
```

Append tasks after `deploy:preview` (mirror smoke style): `load` (safe suite: baseline+availability+soak), `load:check` (internal — verify LAMBDA_API_KEY + vegeta + envsubst), `load:targets` (internal — envsubst render templates to `LOAD_GEN`), `load:baseline`, `load:availability`, `load:soak`, `load:spike` (WARNING printed), `load:throttle` (WARNING + expects 429), `load:list` (per-scenario PASS/FAIL gate: no-429 for under-cap, 429-present for throttle; exit non-zero on violation), `load:url`, `load:clean`.

`load:check` prerequisite block (same gate as `smoke:prod`):
```bash
if [ -z "${LAMBDA_API_KEY:-}" ]; then echo "LAMBDA_API_KEY required (same gate as smoke:prod)." >&2; exit 1; fi
command -v vegeta >/dev/null 2>&1 || { echo "vegeta not found. Install: go install github.com/tsenart/vegeta/v2@latest (or brew install vegeta)" >&2; exit 1; }
command -v envsubst >/dev/null 2>&1 || { echo "envsubst not found. Install: brew install gettext (or apt install gettext-base)" >&2; exit 1; }
```

`load:targets` render block:
```bash
mkdir -p {{.LOAD_GEN}} {{.LOAD_RESULTS}}
export LOAD_URL="{{.LOAD_URL}}" LAMBDA_API_KEY="$LAMBDA_API_KEY" REPO_ROOT="$(pwd)"
for tmpl in {{.LOAD_DIR}}/targets/*.http.tmpl; do
  envsubst < "$tmpl" > "{{.LOAD_GEN}}/$(basename "$tmpl" .tmpl)"
done
```

`load:list` uses a `run()` shell function: runs each scenario, greps `Status Codes` line, asserts 429 count per expectation (want429 yes→429>0, no→429=0), prints ✅/❌, exits non-zero on any fail.

## .gitignore (append)

File: `/Users/birrame.sene/workspace/prototypes/api-command/.gitignore`
```
# Load-testing output (generated gob/report/plot + envsubst-rendered targets; never the key).
load-tests/results/
```

## load-tests/README.md outline

- What: vegeta load tests vs deployed Lambda Function URL only.
- Prereqs: `task`; `vegeta` (`go install github.com/tsenart/vegeta/v2@latest` or `brew install vegeta`); `envsubst` (`brew install gettext`, link or PATH-add `/opt/homebrew/opt/gettext/bin`; Linux `apt install gettext-base`); `LAMBDA_API_KEY` exported.
- Quick start: `export LAMBDA_API_KEY=...`, `task load`, then opt-in `task load:spike` / `task load:throttle`.
- Scenarios table (above) with expected codes.
- Reading results: `<name>.txt` Status Codes + Success ratio; `<name>.html` latency plot.
- Why `load` excludes spike/throttle: self-DoS guardrail.
- Throttle interpretation: 429-dominated = guard active; 0% 429 = investigate.
- Safety/cost: ≤3360 total reqs, ~3000 throttled (non-billing), ~360 billable — negligible. Key required, only authorized operators. Short durations.
- Optional higher-capacity soak (real prod change, reversible): `cd infra && pulumi config set reservedConcurrency 50 && pulumi up --yes`; revert to 5 after.
- Local fixture excluded: tasks never touch `server/`/`BASE_URL`/`PORT`; `LOAD_URL` defaults to Lambda `PROD_URL`.

## Verification (end-to-end)

```bash
# 1. Install
brew install vegeta gettext          # or: go install github.com/tsenart/vegeta/v2@latest

# 2. Gate
export LAMBDA_API_KEY=<pulumi secret>

# 3. Safe suite — all 200, no 429
task load:baseline       # results/baseline.txt → Status Codes [200:10]
task load:availability   # → [200:10]
task load:soak           # → [200:240]

# 4. Spike — mostly 200
task load:spike          # → mostly [200:100]

# 5. Throttle — 429 dominates
task load:throttle        # → [429:<large> 200:<small>]; guard confirmed

# 6. Full PASS/FAIL gate
task load:list           # per-scenario ✅/❌; exits non-zero on violation

# 7. Plots
open load-tests/results/baseline.html load-tests/results/throttle.html
```

Acceptance: baseline/availability/soak = ~100% 200, zero 429; throttle = non-zero 429 (guard active); `load:list` exits 0.

## Files to create / modify

- `Taskfile.yml` (modify — add `LOAD_*` vars + `load:*` tasks)
- `load-tests/README.md` (new)
- `load-tests/targets/get-products.http.tmpl` (new)
- `load-tests/targets/post-availability.http.tmpl` (new)
- `load-tests/targets/soak-mixed.http.tmpl` (new)
- `load-tests/targets/bodies/availability.json` (new)
- `.gitignore` (modify — append `load-tests/results/`)