#!/usr/bin/env bash
# Shared configuration for the RTRRL AWS infra scripts.
# Source this from the other scripts:  source "$(dirname "$0")/env.sh"
# Edit the values marked CHANGE_ME before first use.

# ---- Core -------------------------------------------------------------------
export REGION="eu-north-1"
export ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null)}"

# ---- Storage / image --------------------------------------------------------
export S3_BUCKET="rtrrl-artifacts-007122174918"   # CHANGE_ME if you used another name
export S3_PREFIX="runs"                            # keys: s3://$S3_BUCKET/$S3_PREFIX/<run>/
export ECR_REPO="rtrrl"
export IMAGE_TAG="${IMAGE_TAG:-cpu}"
export ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"
export IMAGE="${ECR_URI}:${IMAGE_TAG}"

# ---- Batch (EC2-backed compute environment) ---------------------------------
export COMPUTE_ENV="rtrrl-cpu-ce"
export JOB_QUEUE="rtrrl-cpu-queue"
export JOB_DEF="rtrrl-cpu-job"
export INSTANCE_TYPE="c7a.xlarge"                  # 4 vCPU / 8 GiB
export MAX_VCPUS="16"                              # cap on concurrent compute
export PROVISIONING="EC2"                          # EC2 or SPOT
export ECS_INSTANCE_ROLE="rtrrl-ecs-instance-role" # instance profile name
export BATCH_JOB_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/rtrrl-batch-job-role"
# Execution role lets the job definition inject secrets (WANDB_API_KEY) into the
# container from Secrets Manager. Created by infra/iam/setup-iam.sh.
export BATCH_EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/rtrrl-batch-execution-role"

# Networking. The jump host is in the DEFAULT VPC (vpc-0a403420fd30ecb83),
# a PUBLIC subnet (172.31.0.0/16). Running Batch in the same VPC's public
# subnet(s) needs no NAT/VPC endpoints (instances get public IPs -> ECR/S3),
# and the Aim server is reachable over the jump host private IP below.
export SUBNET_IDS="subnet-08127d1c5d4de6ac2,subnet-0b8c68ea0a9784758,subnet-01a2aa195678f8411"  # public subnets 1a/1b/1c (auto public IP, c7a available)
export SECURITY_GROUP_ID="sg-0c0ed6b927c5113dc"    # rtrrl-sg: egress all, reaches jump host Aim 53800

# ---- Job resources ----------------------------------------------------------
export JOB_VCPUS="4"
export JOB_MEMORY_MB="7168"                         # leave headroom under 8 GiB

# ---- GPU Batch (optional; created by create-batch.sh --gpu) ------------------
# Brax/JAX are GPU-first; a single mid GPU (A10G/L4) beats many CPU cores. These
# defaults target g5.2xlarge (8 vCPU / 32 GiB / 1x A10G). The GPU image (tag
# below) is built by the GHA matrix from infra/docker/Dockerfile.gpu.
export GPU_IMAGE_TAG="${GPU_IMAGE_TAG:-gpu}"
export GPU_COMPUTE_ENV="rtrrl-gpu-ce"
export GPU_JOB_QUEUE="rtrrl-gpu-queue"
export GPU_JOB_DEF="rtrrl-gpu-job"
export GPU_INSTANCE_TYPE="g5.2xlarge"               # A10G; g6.2xlarge = L4
export GPU_MAX_VCPUS="8"                            # one whole instance at a time
export GPU_JOB_VCPUS="8"
export GPU_JOB_MEMORY_MB="28000"                    # headroom under 32 GiB
export GPU_PER_JOB="1"                              # GPUs per job

# ---- Aim remote tracking server (on the jump host) --------------------------
# Batch containers send live metrics here. Jump host private IP (default VPC).
export AIM_SERVER="aim://172.31.62.192:53800"

# ---- Logging + Weights & Biases ---------------------------------------------
# Default logging backend(s) for submitted jobs: "aim", "wandb", or "aim+wandb".
export LOGGING="${LOGGING:-aim+wandb}"
# PPO runs log to "RTRRL-PPO" (see ppo_baseline.py); keep the sweep in the same
# project so its runs are tracked together.
export WANDB_PROJECT="${WANDB_PROJECT:-RTRRL-PPO}"
# Optional W&B entity (user/team). Leave empty to use your default entity.
export WANDB_ENTITY="${WANDB_ENTITY:-}"
# FULL ARN (with the random suffix) of the Secrets Manager secret holding the
# W&B API key. Create it once and paste the returned ARN here:
#   aws secretsmanager create-secret --name rtrrl/wandb-api-key \
#     --secret-string '<your-key>' --region eu-north-1
# If empty, jobs run WITHOUT WANDB_API_KEY (use only with LOGGING=aim).
export WANDB_SECRET_ARN="${WANDB_SECRET_ARN:-arn:aws:secretsmanager:eu-north-1:007122174918:secret:rtrrl/wandb-api-key-ewMYy3}"
