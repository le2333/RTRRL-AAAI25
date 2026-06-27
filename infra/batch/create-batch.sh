#!/usr/bin/env bash
# Create an AWS Batch EC2-backed compute environment, job queue, and a base job
# definition. Defaults to the CPU setup from env.sh; pass --gpu to create the GPU
# setup (g5.2xlarge etc.), or use the individual flags to build a custom
# environment (e.g. a 16 vCPU c7a.4xlarge env for benchmarking).
#
# Examples:
#   infra/batch/create-batch.sh                     # CPU (env.sh defaults)
#   infra/batch/create-batch.sh --gpu               # GPU (env.sh GPU_* defaults)
#   infra/batch/create-batch.sh \                   # custom 16-vCPU CPU env
#     --compute-env rtrrl-cpu16-ce --queue rtrrl-cpu16-queue \
#     --job-def rtrrl-cpu16-job --instance c7a.4xlarge \
#     --max-vcpus 16 --job-vcpus 16 --job-mem 30000
#
# Flags (all optional; default to env.sh values):
#   --gpu                 use GPU_* defaults + attach 1 GPU + GPU image tag
#   --compute-env NAME    --queue NAME        --job-def NAME
#   --instance TYPE       --max-vcpus N        --provisioning EC2|SPOT
#   --job-vcpus N         --job-mem MIB        --gpus N
#   --image-tag TAG       (ECR tag to run; default cpu, or gpu with --gpu)
#
# Re-running creates only what is missing; the job definition is (re)registered
# as a new revision each time.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/../env.sh"

# ---- defaults (CPU) ---------------------------------------------------------
GPU_MODE=0
CE="${COMPUTE_ENV}"; QUEUE="${JOB_QUEUE}"; JD="${JOB_DEF}"
ITYPE="${INSTANCE_TYPE}"; MAXV="${MAX_VCPUS}"; PROV="${PROVISIONING}"
JV="${JOB_VCPUS}"; JM="${JOB_MEMORY_MB}"; GPUS="0"; TAG="${IMAGE_TAG}"

# First pass: honor --gpu before applying other overrides so GPU_* become the base.
for a in "$@"; do [ "$a" = "--gpu" ] && GPU_MODE=1; done
if [ "${GPU_MODE}" = "1" ]; then
  CE="${GPU_COMPUTE_ENV}"; QUEUE="${GPU_JOB_QUEUE}"; JD="${GPU_JOB_DEF}"
  ITYPE="${GPU_INSTANCE_TYPE}"; MAXV="${GPU_MAX_VCPUS}"
  JV="${GPU_JOB_VCPUS}"; JM="${GPU_JOB_MEMORY_MB}"; GPUS="${GPU_PER_JOB}"
  TAG="${GPU_IMAGE_TAG}"
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --gpu)          shift ;;
    --compute-env)  CE="$2"; shift 2 ;;
    --queue)        QUEUE="$2"; shift 2 ;;
    --job-def)      JD="$2"; shift 2 ;;
    --instance)     ITYPE="$2"; shift 2 ;;
    --max-vcpus)    MAXV="$2"; shift 2 ;;
    --provisioning) PROV="$2"; shift 2 ;;
    --job-vcpus)    JV="$2"; shift 2 ;;
    --job-mem)      JM="$2"; shift 2 ;;
    --gpus)         GPUS="$2"; shift 2 ;;
    --image-tag)    TAG="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

IMAGE="${ECR_URI}:${TAG}"

if [ "${SUBNET_IDS}" = "subnet-CHANGE_ME" ] || [ "${SECURITY_GROUP_ID}" = "sg-CHANGE_ME" ]; then
  echo "ERROR: set SUBNET_IDS and SECURITY_GROUP_ID in infra/env.sh first." >&2
  exit 1
fi

INSTANCE_PROFILE_ARN="arn:aws:iam::${ACCOUNT_ID}:instance-profile/${ECS_INSTANCE_ROLE}"

echo "compute env : ${CE}  (instance ${ITYPE}, ${PROV}, max ${MAXV} vCPU)"
echo "job queue   : ${QUEUE}"
echo "job def     : ${JD}  (image ${IMAGE}; ${JV} vCPU / ${JM} MiB / ${GPUS} GPU)"

# ---- 1. Compute environment --------------------------------------------------
# NOTE: query length(); an empty list's [0] prints "None" under --output text,
# which would falsely look like the resource exists.
CE_COUNT=$(aws batch describe-compute-environments --compute-environments "${CE}" \
  --region "${REGION}" --query "length(computeEnvironments)" --output text 2>/dev/null || echo 0)
if [ "${CE_COUNT}" != "0" ]; then
  echo "compute environment ${CE} already exists"
else
  echo "creating compute environment ${CE} (${ITYPE}, ${PROV})..."
  # Build the subnets JSON array from the comma-separated list.
  SUBNET_JSON=$(printf '"%s",' ${SUBNET_IDS//,/ }); SUBNET_JSON="[${SUBNET_JSON%,}]"
  aws batch create-compute-environment \
    --region "${REGION}" \
    --compute-environment-name "${CE}" \
    --type MANAGED \
    --state ENABLED \
    --compute-resources "{
      \"type\": \"${PROV}\",
      \"minvCpus\": 0,
      \"maxvCpus\": ${MAXV},
      \"desiredvCpus\": 0,
      \"instanceTypes\": [\"${ITYPE}\"],
      \"subnets\": ${SUBNET_JSON},
      \"securityGroupIds\": [\"${SECURITY_GROUP_ID}\"],
      \"instanceRole\": \"${INSTANCE_PROFILE_ARN}\"
    }"
  echo "waiting for compute environment to become VALID..."
  for _ in $(seq 1 30); do
    status=$(aws batch describe-compute-environments --compute-environments "${CE}" \
      --region "${REGION}" --query "computeEnvironments[0].status" --output text)
    echo "  status=${status}"
    [ "${status}" = "VALID" ] && break
    [ "${status}" = "INVALID" ] && { echo "compute env INVALID; check roles/subnets"; exit 1; }
    sleep 10
  done
fi

# ---- 2. Job queue ------------------------------------------------------------
JQ_COUNT=$(aws batch describe-job-queues --job-queues "${QUEUE}" \
  --region "${REGION}" --query "length(jobQueues)" --output text 2>/dev/null || echo 0)
if [ "${JQ_COUNT}" != "0" ]; then
  echo "job queue ${QUEUE} already exists"
else
  echo "creating job queue ${QUEUE}..."
  aws batch create-job-queue \
    --region "${REGION}" \
    --job-queue-name "${QUEUE}" \
    --state ENABLED \
    --priority 1 \
    --compute-environment-order "order=1,computeEnvironment=${CE}"
fi

# ---- 3. Job definition (base; command is overridden at submit time) ----------
# If a W&B secret ARN is configured, attach an execution role + inject the API
# key from Secrets Manager so jobs can log to W&B.
EXEC_FRAG=""
SECRETS_FRAG=""
if [ -n "${WANDB_SECRET_ARN:-}" ]; then
  EXEC_FRAG="\"executionRoleArn\": \"${BATCH_EXEC_ROLE_ARN}\","
  SECRETS_FRAG="\"secrets\": [{\"name\": \"WANDB_API_KEY\", \"valueFrom\": \"${WANDB_SECRET_ARN}\"}],"
  echo "job definition will inject WANDB_API_KEY from ${WANDB_SECRET_ARN}"
else
  echo "WANDB_SECRET_ARN not set: job definition will NOT inject WANDB_API_KEY (aim-only)"
fi

# Resource requirements: VCPU + MEMORY always; GPU only when requested.
RES_REQS="{\"type\": \"VCPU\", \"value\": \"${JV}\"}, {\"type\": \"MEMORY\", \"value\": \"${JM}\"}"
if [ "${GPUS}" != "0" ]; then
  RES_REQS="${RES_REQS}, {\"type\": \"GPU\", \"value\": \"${GPUS}\"}"
fi

echo "registering job definition ${JD}..."
aws batch register-job-definition \
  --region "${REGION}" \
  --job-definition-name "${JD}" \
  --type container \
  --platform-capabilities EC2 \
  --container-properties "{
    \"image\": \"${IMAGE}\",
    \"command\": [\"python\", \"rtrrl.py\", \"--help\"],
    \"jobRoleArn\": \"${BATCH_JOB_ROLE_ARN}\",
    ${EXEC_FRAG}
    ${SECRETS_FRAG}
    \"resourceRequirements\": [${RES_REQS}],
    \"logConfiguration\": {\"logDriver\": \"awslogs\"}
  }" \
  --query "jobDefinitionArn" --output text

echo
echo "Done: compute env ${CE}, queue ${QUEUE}, job def ${JD}."
echo "Submit a run with infra/submit.sh --queue ${QUEUE} --job-def ${JD} --config <cfg>."
