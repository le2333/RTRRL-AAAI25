#!/usr/bin/env bash
# Build the CPU training image and push it to ECR.
# Run from the jump host (its `controller` role can push to ECR) or anywhere
# with Docker + credentials. Build context is the repo root.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/env.sh"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"

echo "Image: ${IMAGE}"

# Create the ECR repo if it does not exist (needs ecr:CreateRepository; if the
# jump host role lacks it, create the repo once with admin creds instead).
aws ecr describe-repositories --repository-names "${ECR_REPO}" --region "${REGION}" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "${ECR_REPO}" --region "${REGION}" >/dev/null

# Log Docker in to ECR.
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Build (linux/amd64 to match Batch EC2 instances) and push.
docker build \
  --platform linux/amd64 \
  -f "${HERE}/docker/Dockerfile" \
  -t "${IMAGE}" \
  "${REPO_ROOT}"

docker push "${IMAGE}"

echo "Pushed ${IMAGE}"
