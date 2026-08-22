# Load testing (vegeta) — Lambda Function URL only

Vegeta-based load/stress/perf scenarios that target **only** the deployed
Lambda Function URL (`infra/src/index.ts`). They never touch the local Dream
fixture (`server/`), `BASE_URL`, or `PORT`.

Goal: measure latency/throughput under sustained load and validate that the
`reservedConcurrentExecutions=5` DoS guard throttles with HTTP 429.

## Prerequisites

- `task` (https://taskfile.dev)
- `vegeta` — `go install github.com/tsenart/vegeta/v2@latest` or `brew install vegeta`
- `envsubst` — `brew install gettext` (link or PATH-add `/opt/homebrew/opt/gettext/bin`; Linux: `apt install gettext-base`)
- `LAMBDA_API_KEY` exported (same gate as `smoke:prod`)

## Quick start

```bash
export LAMBDA_API_KEY=...        # the Pulumi secret
task load                        # safe suite: baseline + availability + soak
task load:spike                  # opt-in
task load:throttle               # opt-in (expects 429)
task load:list                   # full PASS/FAIL gate (exits non-zero on violation)
```

## Scenarios

In-flight ≈ rate × p50 latency; reserved concurrency cap = 5.

| Scenario | Target | Rate | Dur | Workers | Reqs | Expect |
|---|---|---|---|---|---|---|
| baseline | get-products | 1 | 10s | 1 | 10 | 100% 200 |
| availability | post-availability | 1 | 10s | 1 | 10 | 100% 200 |
| soak | soak-mixed | 2 | 120s | 2 | 240 | ~100% 200 (under cap) |
| spike | get-products | 20 | 5s | 5 | 100 | mostly 200 |
| throttle | get-products-unauth | 50 | 5s | 5 | 250 | large 429 fraction (guard active) |
| auth | get-products | 4 | 30s | 2 | 120 | ~0% app-level 429s |

## Reading results

Each scenario writes three files under `load-tests/results/` (gitignored):

- `<name>.bin` — raw vegeta gob results
- `<name>.txt` — text report: Status Codes + Success ratio + latency percentiles
- `<name>.html` — interactive latency plot (`open load-tests/results/<name>.html`)

## Why `task load` excludes spike/throttle/auth

The default suite is the primary self-DoS guardrail: baseline, availability,
and soak all run well under the concurrency cap and must return ~100% 200 with
zero 429s. Spike and throttle deliberately push past the cap, so they are
opt-in only. `load:auth` is also opt-in because it targets production for 30s
at sustained load.

## Throttle interpretation

A 429-dominated result confirms the unauth-only app-level fixed-window
limiter is firing. **0% 429 = guard inactive → investigate** before relying on
it.

## Auth interpretation

A near-zero app-level 429 result is the regression sentinel: authenticated
traffic must not consume the unauth-only bucket. Reserved-concurrency platform
throttling, if it happens, surfaces as platform 429s and is out of scope for
this task.

## Safety / cost

- ≤3360 total requests per full run; ~3000 of those are throttled (non-billing),
  ~360 billable — negligible.
- Requires `LAMBDA_API_KEY`; only authorized operators should run these.
- Durations are short (3–120s) by design.

## Optional higher-capacity soak

To soak at higher concurrency (a real, reversible production change):

```bash
cd infra
pulumi config set reservedConcurrency 50
pulumi up --yes
# ... run load:soak ...
pulumi config set reservedConcurrency 5
pulumi up --yes
```

## Local fixture excluded

The load tasks never reference `server/`, `BASE_URL`, or `PORT`. `LOAD_URL`
defaults to the Lambda `PROD_URL` (Taskfile var); override with
`task load:baseline LOAD_URL=...` if ever needed.
