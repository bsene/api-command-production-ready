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

// --- Custom Go Lambda (provided.al2023 / bootstrap) -------------------------

// The handler is a Go binary named "bootstrap", built by `npm run build:lambda`
// into dist/lambda.zip (GOOS=linux GOARCH=arm64). On the provided.al2023 custom
// runtime AWS executes the "bootstrap" file from the deployment package.
const lambdaZip = path.join(__dirname, "..", "dist", "lambda.zip");

const fn = new aws.lambda.Function(
  "api-command-lambda",
  {
    name: `${namePrefix}-fn`,
    role: lambdaRole.arn,
    runtime: "provided.al2023",
    handler: "bootstrap", // ignored by the custom runtime, but conventional
    architectures: ["arm64"],
    code: new pulumi.asset.FileArchive(lambdaZip),
    timeout: 15,
    memorySize: 128,
    tags: commonTags,
  },
  {
    provider,
    // The role policy attachment must be in place before the function runs.
    dependsOn: [lambdaExecutionPolicy],
  },
);

// --- Function URL (public HTTPS endpoint) ------------------------------------

// A Lambda Function URL is a dedicated HTTPS endpoint AWS provisions for the
// function, so it is reachable with a plain HTTP call (no API Gateway).
// authorizationType "NONE" keeps it curl-testable for this dev kata; flip to
// "AWS_IAM" (SigV4-signed requests) if the handler ever carries real logic.
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
// InvokeFunction action to '*' (dev-only; use AWS_IAM auth in production).
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
