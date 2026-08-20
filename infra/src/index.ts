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

// --- Outputs -----------------------------------------------------------------

export const lambdaName = fn.name;
export const lambdaArn = fn.arn;
export const lambdaRoleArn = lambdaRole.arn;
export const runtime = pulumi.output("provided.al2023");
export const region = pulumi.output(awsRegion);
