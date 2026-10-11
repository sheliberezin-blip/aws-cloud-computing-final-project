#!/usr/bin/env bash
# Stage 8 — let GitHub Actions deploy without any AWS keys stored in GitHub:
#   * GitHub's OIDC identity provider in IAM
#   * an IAM role that ONLY this repo's main branch can assume
#   * a least-privilege policy scoped to this project's resources
# Then verifies the scoping with iam simulate-principal-policy.
# Safe to run more than once.
set -euo pipefail

export AWS_REGION=eu-north-1
GITHUB_REPO=sheliberezin-blip/aws-cloud-computing-final-project
ROLE=final-project-github-actions

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET=final-project-frontend-$ACCOUNT
DIST_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='final-project-frontend'].Id | [0]" --output text)
PROVIDER_ARN=arn:aws:iam::$ACCOUNT:oidc-provider/token.actions.githubusercontent.com
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- 1. OIDC provider (one per account) ---
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" >/dev/null 2>&1; then
  aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null
  echo "created OIDC provider"
fi

# --- 2. Role: trust ONLY pushes to main of this one repo ---
cat > "$TMP/trust.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [ {
    "Effect": "Allow",
    "Principal": { "Federated": "$PROVIDER_ARN" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:$GITHUB_REPO:ref:refs/heads/main"
      }
    }
  } ]
}
EOF
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE" --policy-document "file://$TMP/trust.json"
else
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document "file://$TMP/trust.json" >/dev/null
  echo "created role $ROLE"
fi

# --- 3. Permissions: exactly what deploy.yml needs, on this project's resources only ---
cat > "$TMP/policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "EcrLogin", "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
    { "Sid": "EcrPushProjectRepos", "Effect": "Allow",
      "Action": ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
                 "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage"],
      "Resource": ["arn:aws:ecr:$AWS_REGION:$ACCOUNT:repository/final-project-visits-service",
                   "arn:aws:ecr:$AWS_REGION:$ACCOUNT:repository/final-project-stats-service"] },
    { "Sid": "SsmRunOnProjectInstances", "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": "arn:aws:ec2:$AWS_REGION:$ACCOUNT:instance/*",
      "Condition": { "StringLike": { "ssm:resourceTag/Name": "final-project-*" } } },
    { "Sid": "SsmShellDocumentOnly", "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": "arn:aws:ssm:$AWS_REGION::document/AWS-RunShellScript" },
    { "Sid": "SsmReadResults", "Effect": "Allow",
      "Action": "ssm:GetCommandInvocation", "Resource": "*" },
    { "Sid": "ReadOnlyLookups", "Effect": "Allow",
      "Action": ["ec2:DescribeInstances", "rds:DescribeDBInstances", "cloudfront:ListDistributions",
                 "elasticloadbalancing:DescribeLoadBalancers", "elasticloadbalancing:DescribeTargetGroups",
                 "elasticloadbalancing:DescribeTargetHealth"],
      "Resource": "*" },
    { "Sid": "FrontendBucketList", "Effect": "Allow",
      "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::$BUCKET" },
    { "Sid": "FrontendBucketWrite", "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], "Resource": "arn:aws:s3:::$BUCKET/*" },
    { "Sid": "InvalidateProjectDistribution", "Effect": "Allow",
      "Action": "cloudfront:CreateInvalidation",
      "Resource": "arn:aws:cloudfront::$ACCOUNT:distribution/$DIST_ID" }
  ]
}
EOF
aws iam put-role-policy --role-name "$ROLE" --policy-name final-project-deploy --policy-document "file://$TMP/policy.json"
ROLE_ARN=$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)

# --- 4. Verify the scoping (what the demo asks for) ---
sim() { # action resource expected
  local got
  got=$(aws iam simulate-principal-policy --policy-source-arn "$ROLE_ARN" \
    --action-names "$1" --resource-arns "$2" --query 'EvaluationResults[0].EvalDecision' --output text)
  printf '  %-6s %-32s %-70s %s\n' "$([ "$got" = "$3" ] && echo OK || echo WRONG)" "$1" "$2" "$got"
}
echo
echo "simulate-principal-policy for $ROLE_ARN:"
echo " should be ALLOWED (this project's resources):"
sim ecr:PutImage               "arn:aws:ecr:$AWS_REGION:$ACCOUNT:repository/final-project-visits-service" allowed
sim s3:PutObject               "arn:aws:s3:::$BUCKET/index.html"                                          allowed
sim cloudfront:CreateInvalidation "arn:aws:cloudfront::$ACCOUNT:distribution/$DIST_ID"                     allowed
echo " should be DENIED (everything else):"
sim ecr:PutImage               "arn:aws:ecr:$AWS_REGION:$ACCOUNT:repository/some-other-repo"             implicitDeny
sim s3:PutObject               "arn:aws:s3:::some-other-bucket/file"                                     implicitDeny
sim s3:DeleteBucket            "arn:aws:s3:::$BUCKET"                                                    implicitDeny
sim ec2:TerminateInstances     "arn:aws:ec2:$AWS_REGION:$ACCOUNT:instance/*"                             implicitDeny
sim rds:DeleteDBInstance       "arn:aws:rds:$AWS_REGION:$ACCOUNT:db:final-project-db"                    implicitDeny
sim iam:CreateUser             "arn:aws:iam::$ACCOUNT:user/x"                                            implicitDeny
echo
echo "Role ARN for deploy.yml: $ROLE_ARN"
