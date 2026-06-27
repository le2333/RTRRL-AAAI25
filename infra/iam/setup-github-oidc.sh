#!/usr/bin/env bash
# One-time setup so GitHub Actions can push images to ECR via OIDC (no stored
# AWS keys). Run ONCE with admin/IAM-capable credentials (local or CloudShell).
#
# Creates:
#   - the GitHub OIDC identity provider (if missing)
#   - role rtrrl-github-actions-role trusted by repo le2333/RTRRL-AAAI25
#   - an inline policy allowing ECR create/push
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ROLE="rtrrl-github-actions-role"
PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

echo "Account: ${ACCOUNT_ID}"

# 1) OIDC provider (idempotent). Thumbprint is the well-known GitHub value;
#    AWS validates GitHub OIDC via its trust store, but the param is required.
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${PROVIDER_ARN}" >/dev/null 2>&1; then
  echo "OIDC provider already exists"
else
  echo "creating GitHub OIDC provider..."
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null
fi

# 2) Role trusted by the repo's Actions workflows.
aws iam create-role --role-name "${ROLE}" \
  --assume-role-policy-document "file://${HERE}/github-actions-trust.json" \
  2>/dev/null && echo "created role ${ROLE}" || echo "role ${ROLE} exists"

# 3) ECR create/push permissions.
aws iam put-role-policy --role-name "${ROLE}" \
  --policy-name rtrrl-gha-ecr \
  --policy-document "file://${HERE}/github-actions-policy.json"

echo
echo "Done. Role: arn:aws:iam::${ACCOUNT_ID}:role/${ROLE}"
echo "Push to the main branch (or run the workflow manually) to build and push the image."
