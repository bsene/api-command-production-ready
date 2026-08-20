# api-command-infra (Pulumi AWS, local backend, custom Go Lambda)

Infrastructure-as-code for the `api-command` project, managed with
[Pulumi](https://www.pulumi.com/) using the **local backend** (file-based state
under `~/.pulumi`, no Pulumi Cloud account) and a **custom Go Lambda function**
on the `provided.al2023` custom runtime (a `bootstrap` binary, linux/arm64).

## Prerequisites

- Pulumi CLI (`pulumi version` >= 3.x)
- Node.js >= 20
- Go >= 1.21 (for the Lambda handler build)
- AWS credentials via a named profile in `~/.aws/credentials`

## Local backend

State and stack metadata are stored on disk under `~/.pulumi` (not in this
repo). The local backend encrypts config secrets with a passphrase, so every
Pulumi command needs `PULUMI_CONFIG_PASSPHRASE`:

```sh
export PULUMI_CONFIG_PASSPHRASE="api-command-local-dev"
export AWS_PROFILE=default
```

(Add these to your shell rc or a local, un-committed `.env`.)

## Stack configuration (`Pulumi.dev.yaml`)

| key           | value     | meaning                          |
|---------------|-----------|----------------------------------|
| `aws:region`  | eu-north-1 | AWS region for resources         |
| `aws:profile` | default   | AWS credentials profile to use    |

```sh
pulumi config set aws:region eu-west-1
pulumi config set aws:profile perso
```

## The custom Go Lambda

The Lambda runs on the **`provided.al2023` custom runtime**: AWS executes a
binary named `bootstrap` from the deployment package. The handler is a
standalone Go module under `lambda/` (its own `go.mod`, so the kata's root
module is untouched) using `github.com/aws/aws-lambda-go`.

```
infra/
  lambda/             # separate Go module (api-command/lambda)
    go.mod            # requires github.com/aws/aws-lambda-go
    main.go           # handler: receives a Request, returns a Response
  dist/               # build output (gitignored)
    bootstrap         # GOOS=linux GOARCH=arm64 binary
    lambda.zip        # zipped bootstrap -> Lambda code package
  src/index.ts        # Pulumi program: IAM role + aws.lambda.Function
  ...
```

### Build

The npm script cross-compiles the handler and zips it as `bootstrap`:

```sh
npm run build:lambda   # -> dist/lambda.zip
```

This is wired into `preview`/`up`, so you normally just run:

```sh
npm install            # first time only
pulumi preview         # builds the zip, then dry-runs
pulumi up              # builds the zip, then applies
pulumi destroy         # tear everything down
```

### Runtime details

- `runtime: "provided.al2023"` — AWS-provided OS-only runtime; the `bootstrap`
  binary implements the Lambda Runtime API (driven here by `aws-lambda-go`).
- `architectures: ["arm64"]` — Graviton, built with `GOARCH=arm64`.
- `handler: "bootstrap"` — required entry name on the custom runtime.
- IAM role: `lambda.amazonaws.com` trust + `AWSLambdaBasicExecutionRole`
  (CloudWatch Logs write).

## Outputs

| output            | example value                                              |
|-------------------|------------------------------------------------------------|
| `lambdaName`      | `api-command-infra-dev-fn`                                 |
| `lambdaArn`       | (resolved after `pulumi up`)                               |
| `lambdaRoleArn`   | (resolved after `pulumi up`)                               |
| `runtime`         | `provided.al2023`                                          |
| `region`          | `eu-north-1` (parsed from `lambdaArn`)                     |
| `functionUrl`     | `https://<id>.lambda-url.eu-north-1.on.aws/`              |
| `functionUrlArn`  | (resolved after `pulumi up`)                               |

## Function URL

The Lambda has a **Function URL**: a dedicated HTTPS endpoint AWS provisions
for the function (no API Gateway). It uses `authorizationType: "NONE"`, meaning
AWS does not enforce IAM SigV4 signing at the edge — but **the handler
authenticates every request** by comparing the `x-api-key` header against the
`LAMBDA_API_KEY` environment variable (constant-time comparison). Requests
without a matching key are rejected with `401` before any business logic runs.

### Setting the API key

The key is stored as a Pulumi secret (encrypted in state, never in source):

```sh
pulumi config set --secret lambdaApiKey "your-secret-key"
```

If the key is not configured, the handler returns `500` and refuses to serve —
**fail-closed, not fail-open**.

A Function URL is only actually public if the function's resource-based policy
grants `lambda:InvokeFunctionUrl` to `*` (with the `FunctionUrlAuthType == NONE`
condition) — `src/index.ts` provisions that via `aws.lambda.Permission`, plus a
second permission for `lambda:InvokeFunction` (required since Oct 2025 for
unauthenticated Function URL invocations). The handler-level `x-api-key` check
is what actually gates access (A01 broken access control).

Function URLs deliver requests as **API Gateway v2 (HTTP API) payload-format-2.0
events**, so the handler reads the HTTP body from `event.Body` (see
`lambda/main.go`), not from the top-level event.

Invoke it directly:

```sh
curl -X POST "$(pulumi stack output functionUrl)" \
  -H 'Content-Type: application/json' \
  -H 'x-api-key: your-secret-key' \
  -d '{"ref":1,"description":"ball","stock":3,"price":9.9}'
# -> {"ok":true,"ref":1,"message":"ref=1 description=\"ball\" stock=3 price=9.90 -> available=true"}
```

Without the `x-api-key` header (or with the wrong key):

```sh
curl -X POST "$(pulumi stack output functionUrl)" \
  -H 'Content-Type: application/json' \
  -d '{"ref":1,"description":"ball","stock":3,"price":9.9}'
# -> {"error":"unauthorized"}   (HTTP 401)
```

## Notes

- `lambda/main.go` authenticates every request via the `x-api-key` header
  (A01). Replace the placeholder business logic with the real api-command
  logic — the auth check stays as the first gate.
- The API key is a Pulumi config secret (`lambdaApiKey`). Set it before
  `pulumi up` or the handler will refuse to serve.
- Never commit `~/.pulumi` state, the passphrase, or `dist/`.
