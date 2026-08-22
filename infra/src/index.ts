import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";
import * as path from "node:path";

// --- Configuration -----------------------------------------------------------

const config = new pulumi.Config("aws");
const awsRegion = config.get("region") ?? "us-east-1";
const awsProfile = config.get("profile") ?? "default";

// Explicit provider so resources land in the chosen region/profile.
const provider = new aws.Provider("aws", {
  region: awsRegion as aws.Region,
  profile: awsProfile,
});

const project = pulumi.getProject();
const stack = pulumi.getStack();
const namePrefix = `${project}-${stack}`;
const commonTags = {
  Project: project,
  Stack: stack,
  ManagedBy: "pulumi",
};

// --- API key (application-level auth, A01) ------------------------------------

// The Lambda handler authenticates every request by comparing the x-api-key
// header against this value (constant-time comparison in OCaml). The key is
// stored as a Pulumi secret so it is encrypted at rest in the Pulumi state and
// never appears in plaintext in the stack config or source.
//
// Set it at deploy time (must be at least 32 bytes — generate a strong key):
//
//   pulumi config set --secret api-command-infra:lambdaApiKey "$(openssl rand -hex 32)"
//
// The key is validated here at deploy time: a short/weak key fails
// `pulumi preview`/`up` before anything is provisioned. If left empty the
// handler refuses to serve (returns 500) — fail-closed, not fail-open.
const lambdaApiKey = new pulumi.Config().requireSecret("lambdaApiKey").apply((key) => {
  if (key.length < 32) {
    throw new Error(
      `lambdaApiKey must be at least 32 bytes (got ${key.length}); generate one with: openssl rand -hex 32`,
    );
  }
  return key;
});

// Reserved concurrency caps how many instances of this function can run at
// once, so a flood of requests cannot exhaust the account's concurrency pool
// and starve other functions (billing/cost DoS + concurrency exhaustion).
// Override with: pulumi config set reservedConcurrency N
const reservedConcurrency = new pulumi.Config().getNumber("reservedConcurrency") ?? 5;

// --- IAM role for the Lambda -------------------------------------------------

// Trust policy: allow Lambda's service to assume the role.
const lambdaRole = new aws.iam.Role(
  "lambda-role",
  {
    name: `${namePrefix}-role`,
    assumeRolePolicy: JSON.stringify({
      Version: "2012-10-17",
      Statement: [
        {
          Effect: "Allow",
          Principal: { Service: "lambda.amazonaws.com" },
          Action: "sts:AssumeRole",
        },
      ],
    }),
    tags: commonTags,
  },
  { provider },
);

// Attach the basic execution policy (CloudWatch Logs create/write).
const lambdaExecutionPolicy = new aws.iam.RolePolicyAttachment(
  "lambda-basic-exec",
  {
    role: lambdaRole.name,
    policyArn: aws.iam.ManagedPolicy.AWSLambdaBasicExecutionRole,
  },
  { provider },
);

// --- Custom OCaml Lambda (provided.al2023 / bootstrap) -----------------------

// The handler is an OCaml binary named "bootstrap", cross-compiled to
// linux/arm64 by `npm run build:lambda` via `Dockerfile.lambda` (Docker buildx)
// into dist/lambda.zip. On the provided.al2023 custom runtime AWS executes the
// "bootstrap" file from the deployment package.
const lambdaZip = path.join(__dirname, "..", "dist", "lambda.zip");
const catalogLayerZip = path.join(__dirname, "..", "dist", "catalog-layer.zip");

// --- Product catalog Lambda layer -------------------------------------------

// A Lambda LayerVersion ships the product-catalog reference data
// (infra/catalog/products.json, built by `npm run build:layer` into
// dist/catalog-layer.zip) to every execution environment of the function. AWS
// backs layer content with S3 internally and mounts it read-only at /opt, so:
//   - no aws.s3.Bucket resource is needed, and
//   - no S3 read permission is needed on the Lambda role (the layer is mounted
//     by the Lambda runtime at environment setup, not fetched per invocation).
// The zip entry catalog/products.json lands at /opt/catalog/products.json,
// which the handler loads at startup (see lambda/main.ml).
const catalogLayer = new aws.lambda.LayerVersion(
  "catalog-layer",
  {
    layerName: `${namePrefix}-catalog`,
    code: new pulumi.asset.FileArchive(catalogLayerZip),
    compatibleArchitectures: ["arm64"],
    compatibleRuntimes: ["provided.al2023"],
    description: "Product catalog reference data for api-command",
  },
  { provider },
);

const fn = new aws.lambda.Function(
  "api-command-lambda",
  {
    name: `${namePrefix}-fn`,
    role: lambdaRole.arn,
    runtime: "provided.al2023",
    handler: "bootstrap", // ignored by the custom runtime, but conventional
    architectures: ["arm64"],
    code: new pulumi.asset.FileArchive(lambdaZip),
    layers: [catalogLayer.arn],
    // 512 MB (not 128): Lambda CPU share scales with memory, and the 20.6 MB
    // dynamically-linked OCaml bootstrap (glibc + libev + libgmp + cohttp/lwt/
    // conduit) is marginal at the 128 MB / minimum-CPU tier. Max memory used is
    // ~41 MB, so 512 MB is cold-start headroom, not waste. Pairs with the
    // runtime-loop diagnostics + retry cap (lambda/runtime.ml) so a permanent
    // Runtime-API error surfaces as a one-line error, not a 20 s timeout.
    timeout: 30,
    memorySize: 512,
    reservedConcurrentExecutions: reservedConcurrency,
    // Inject the API key as a Lambda env var (Pulumi masks it because it came
    // from requireSecret — see the api-key block above for the full rationale).
    environment: {
      variables: {
        LAMBDA_API_KEY: lambdaApiKey,
      },
    },
    tags: commonTags,
  },
  {
    provider,
    // The role policy attachment must be in place before the function runs.
    // The catalog layer must exist before the function references its ARN.
    dependsOn: [lambdaExecutionPolicy, catalogLayer],
  },
);

// --- Function URL (public HTTPS endpoint) ------------------------------------

// A Lambda Function URL is a dedicated HTTPS endpoint AWS provisions for the
// function, so it is reachable with a plain HTTP call (no API Gateway).
//
// authorizationType "NONE" means AWS does not enforce IAM SigV4 signing at the
// edge — but the handler authenticates every request via the x-api-key header
// (see lambda/main.ml). This keeps the endpoint curl-testable while
// still rejecting unauthenticated callers with 401.
const fnUrl = new aws.lambda.FunctionUrl(
  "api-command-fn-url",
  {
    functionName: fn.name,
    authorizationType: "NONE",
    invokeMode: "BUFFERED",
  },
  { provider, dependsOn: [fn] },
);

// Resource-based policy: with authorizationType "NONE" the function URL is
// public only if the function grants lambda:InvokeFunctionUrl to everyone.
// Without this, AWS denies unauthenticated invocations (the console warning).
const fnUrlPermission = new aws.lambda.Permission(
  "api-command-fn-url-perm",
  {
    action: "lambda:InvokeFunctionUrl",
    function: fn.name,
    principal: "*",
    // functionUrlAuthType sets the lambda:FunctionUrlAuthType == NONE
    // condition, which AWS requires when granting InvokeFunctionUrl to "*".
    // No sourceArn: the invocation's SourceArn is the Function URL ARN
    // (...:function:<name>:url), which differs from the function ARN — pinning
    // it here would deny every unauthenticated call.
    functionUrlAuthType: "NONE",
  },
  { provider, dependsOn: [fnUrl] },
);

// Additional permission required since Oct 2025 for Function URLs:
// AWS now requires both lambda:InvokeFunctionUrl AND lambda:InvokeFunction
// in the resource policy for unauthenticated Function URL invocations.
// Pulumi v6 does not expose `invokedViaFunctionUrl`, so we grant the plain
// InvokeFunction action to '*' — the handler-level x-api-key check is what
// actually gates access (A01).
const fnInvokePermission = new aws.lambda.Permission(
  "api-command-fn-invoke-perm",
  {
    action: "lambda:InvokeFunction",
    function: fn.name,
    principal: "*",
  },
  { provider, dependsOn: [fnUrl] },
);

// --- Outputs -----------------------------------------------------------------

export const lambdaName = fn.name;
export const functionUrl = fnUrl.functionUrl; // https://<id>.lambda-url.<region>.on.aws/
export const functionUrlArn = fnUrl.functionArn;
export const lambdaArn = fn.arn;
export const lambdaRoleArn = lambdaRole.arn;
export const runtime = pulumi.output("provided.al2023");
// Derived from the deployed Lambda's ARN, not the config string, so the
// output reflects where the function actually lives — config-vs-reality drift
// surfaces as a mismatch between `aws:region` and this value.
export const region = fn.arn.apply((arn) => {
  // arn:aws:lambda:<region>:<acct>:function:<name>
  return String(arn).split(":")[3];
});
