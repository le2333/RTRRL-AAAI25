#!/usr/bin/env bash
# Create the AWS Batch EC2-backed compute environment, job queue, and a base
# job definition for CPU training (e.g. c7a.xlarge).
# Run once with credentials that can create Batch resources (the jump host
# `controller` role can, or use admin creds). Re-running creates only what is
# missing; the job definition is (re)registered as a new revision each time.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/../env.sh"

if [ "${SUBNET_IDS}" = "subnet-CHANGE_ME" ] || [ "${SECURITY_GROUP_ID}" = "sg-CHANGE_ME" ]; then
  echo "ERROR: set SUBNET_IDS and SECURITY_GROUP_ID in infra/env.sh first." >&2
  exit 1
fi

INSTANCE_PROFILE_ARN="arn:aws:iam::${ACCOUNT_ID}:instance-profile/${ECS_INSTANCE_ROLE}"

# ---- 1. Compute environment --------------------------------------------------
# NOTE: query length(); an empty list's [0] prints "None" under --output text,
# which would falsely look like the resource exists.
CE_COUNT=$(aws batch describe-compute-environments --compute-environments "${COMPUTE_ENV}" \
  --region "${REGION}" --query "length(computeEnvironments)" --output text 2>/dev/null || echo 0)
if [ "${CE_COUNT}" != "0" ]; then
  echo "compute environment ${COMPUTE_ENV} already exists"
else
  echo "creating compute environment ${COMPUTE_ENV} (${INSTANCE_TYPE}, ${PROVISIONING})..."
  # Build the subnets JSON array from the comma-separated list.
  SUBNET_JSON=$(printf '"%s",' ${SUBNET_IDS//,/ }); SUBNET_JSON="[${SUBNET_JSON%,}]"
  aws batch create-compute-environment \
    --region "${REGION}" \
    --compute-environment-name "${COMPUTE_ENV}" \
    --type MANAGED \
    --state ENABLED \
    --compute-resources "{
      \"type\": \"${PROVISIONING}\",
      \"minvCpus\": 0,
      \"maxvCpus\": ${MAX_VCPUS},
      \"desiredvCpus\": 0,
      \"instanceTypes\": [\"${INSTANCE_TYPE}\"],
      \"subnets\": ${SUBNET_JSON},
      \"securityGroupIds\": [\"${SECURITY_GROUP_ID}\"],
      \"instanceRole\": \"${INSTANCE_PROFILE_ARN}\"
    }"
  echo "waiting for compute environment to become VALID..."
  for _ in $(seq 1 30); do
    status=$(aws batch describe-compute-environments --compute-environments "${COMPUTE_ENV}" \
      --region "${REGION}" --query "computeEnvironments[0].status" --output text)
    echo "  status=${status}"
    [ "${status}" = "VALID" ] && break
    [ "${status}" = "INVALID" ] && { echo "compute env INVALID; check roles/subnets"; exit 1; }
    sleep 10
  done
fi

# ---- 2. Job queue ------------------------------------------------------------
JQ_COUNT=$(aws batch describe-job-queues --job-queues "${JOB_QUEUE}" \
  --region "${REGION}" --query "length(jobQueues)" --output text 2>/dev/null || echo 0)
if [ "${JQ_COUNT}" != "0" ]; then
  echo "job queue ${JOB_QUEUE} already exists"
else
  echo "creating job queue ${JOB_QUEUE}..."
  aws batch create-job-queue \
    --region "${REGION}" \
    --job-queue-name "${JOB_QUEUE}" \
    --state ENABLED \
    --priority 1 \
    --compute-environment-order "order=1,computeEnvironment=${COMPUTE_ENV}"
fi

# ---- 3. Job definition (base; command is overridden at submit time) ----------
echo "registering job definition ${JOB_DEF}..."
aws batch register-job-definition \
  --region "${REGION}" \
  --job-definition-name "${JOB_DEF}" \
  --type container \
  --platform-capabilities EC2 \
  --container-properties "{
    \"image\": \"${IMAGE}\",
    \"command\": [\"python\", \"rtrrl.py\", \"--help\"],
    \"jobRoleArn\": \"${BATCH_JOB_ROLE_ARN}\",
    \"resourceRequirements\": [
      {\"type\": \"VCPU\", \"value\": \"${JOB_VCPUS}\"},
      {\"type\": \"MEMORY\", \"value\": \"${JOB_MEMORY_MB}\"}
    ],
    \"logConfiguration\": {\"logDriver\": \"awslogs\"}
  }" \
  --query "jobDefinitionArn" --output text

echo
echo "Done: compute env ${COMPUTE_ENV}, queue ${JOB_QUEUE}, job def ${JOB_DEF}."
echo "Submit a run with infra/submit.sh."
