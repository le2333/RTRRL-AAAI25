#!/usr/bin/env bash
# Create / update IAM for the RTRRL jump host (control plane) and AWS Batch
# running on an EC2-backed compute environment (ECS launch type, e.g. c7a.xlarge).
#
# Run with admin/IAM-capable credentials (your local profile or AWS CloudShell),
# NOT from the jump host's own limited role.
#
# Jump host: this instance already has an instance profile ("controller"), and an
# instance can only have ONE profile, so we ATTACH the control-plane permissions
# to that existing role instead of creating/associating a new profile.
set -euo pipefail

# ---- Fill these in ----------------------------------------------------------
REGION="eu-north-1"
BUCKET="rtrrl-artifacts-007122174918"  # S3 bucket for checkpoints / artifacts
ECR_REPO="rtrrl"                       # ECR repository name for the training image
JUMP_ROLE="controller"                 # existing instance role on the jump host
USE_SPOT="false"                       # set true to also create the Spot fleet role
# -----------------------------------------------------------------------------

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$(mktemp -d)"
echo "Account: ${ACCOUNT_ID}  Region: ${REGION}  JumpRole: ${JUMP_ROLE}"

render() { # render <src.json> <dst.json>
  sed -e "s|__ACCOUNT_ID__|${ACCOUNT_ID}|g" \
      -e "s|__REGION__|${REGION}|g" \
      -e "s|__BUCKET__|${BUCKET}|g" \
      -e "s|__ECR_REPO__|${ECR_REPO}|g" \
      "$1" > "$2"
}

render "${DIR}/jump-host-policy.json" "${BUILD}/jump-host-policy.json"
render "${DIR}/batch-job-policy.json" "${BUILD}/batch-job-policy.json"
render "${DIR}/batch-execution-policy.json" "${BUILD}/batch-execution-policy.json"

# 1) Jump host: attach control-plane perms to the EXISTING role ----------------
#    (Batch submit/monitor, S3 artifacts, ECR push/pull, CW logs read, PassRole)
#    Tolerant: when run FROM the jump host, the controller role usually cannot
#    modify itself; in that case this step is skipped (do it once with admin
#    creds, which is the documented manual step).
aws iam put-role-policy --role-name "${JUMP_ROLE}" \
  --policy-name rtrrl-control-plane \
  --policy-document "file://${BUILD}/jump-host-policy.json" \
  2>/dev/null && echo "applied rtrrl-control-plane to ${JUMP_ROLE}" \
  || echo "skip ${JUMP_ROLE} self-modify (no perms or already configured)"
aws iam attach-role-policy --role-name "${JUMP_ROLE}" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
  2>/dev/null && echo "attached SSM core to ${JUMP_ROLE}" \
  || echo "skip SSM core on ${JUMP_ROLE} (no perms or already attached)"

# 2) ECS instance role for the Batch EC2 compute environment (c7a.xlarge) -------
#    Runs the ECS agent on the compute instances; includes ECR pull + ECS register.
ECS_ROLE="rtrrl-ecs-instance-role"
aws iam create-role --role-name "${ECS_ROLE}" \
  --assume-role-policy-document "file://${DIR}/ecs-instance-trust.json" \
  2>/dev/null || echo "role ${ECS_ROLE} exists"
aws iam attach-role-policy --role-name "${ECS_ROLE}" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role
#    Optional but handy: SSM on compute nodes for debugging.
aws iam attach-role-policy --role-name "${ECS_ROLE}" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
  2>/dev/null || true
aws iam create-instance-profile --instance-profile-name "${ECS_ROLE}" \
  2>/dev/null || echo "instance profile ${ECS_ROLE} exists"
aws iam add-role-to-instance-profile --instance-profile-name "${ECS_ROLE}" \
  --role-name "${ECS_ROLE}" 2>/dev/null || echo "role already in profile"

# 3) Batch job role (what the training container can do: S3 + CW logs) ---------
JOB_ROLE="rtrrl-batch-job-role"
aws iam create-role --role-name "${JOB_ROLE}" \
  --assume-role-policy-document "file://${DIR}/batch-task-trust.json" \
  2>/dev/null || echo "role ${JOB_ROLE} exists"
aws iam put-role-policy --role-name "${JOB_ROLE}" \
  --policy-name rtrrl-batch-job-inline \
  --policy-document "file://${BUILD}/batch-job-policy.json"

# 3b) Batch execution role (ECS pulls image + injects secrets into the task) ----
#     Needed so the job definition can inject WANDB_API_KEY from Secrets Manager.
EXEC_ROLE="rtrrl-batch-execution-role"
aws iam create-role --role-name "${EXEC_ROLE}" \
  --assume-role-policy-document "file://${DIR}/batch-task-trust.json" \
  2>/dev/null || echo "role ${EXEC_ROLE} exists"
aws iam attach-role-policy --role-name "${EXEC_ROLE}" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
aws iam put-role-policy --role-name "${EXEC_ROLE}" \
  --policy-name rtrrl-batch-execution-secrets \
  --policy-document "file://${BUILD}/batch-execution-policy.json"

# 4) Optional: Spot fleet role (only if the compute env uses Spot) --------------
if [ "${USE_SPOT}" = "true" ]; then
  aws iam create-role --role-name AmazonEC2SpotFleetTaggingRole \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"spotfleet.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    2>/dev/null || echo "Spot fleet role exists"
  aws iam attach-role-policy --role-name AmazonEC2SpotFleetTaggingRole \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole
fi

rm -rf "${BUILD}"
echo
echo "Done."
echo "  Jump host role (${JUMP_ROLE}): +rtrrl-control-plane inline, +SSM core"
echo "  ECS instance role:            ${ECS_ROLE} (+ instance profile)"
echo "  Batch job role:               ${JOB_ROLE}"
[ "${USE_SPOT}" = "true" ] && echo "  Spot fleet role:              AmazonEC2SpotFleetTaggingRole"
echo
echo "The Batch service-linked role (AWSServiceRoleForBatch) is created"
echo "automatically when you first create a Batch compute environment."
echo
echo "When creating the EC2 compute environment, use instance role"
echo "  ${ECS_ROLE}  and instance type c7a.xlarge."
