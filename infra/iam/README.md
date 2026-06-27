# IAM for RTRRL (jump host + AWS Batch on EC2-backed compute)

Batch runs on an **EC2-backed compute environment** (ECS launch type, e.g.
`c7a.xlarge`), not Fargate.

| Role | Trusted by | What it can do |
| --- | --- | --- |
| `controller` (existing jump-host role) | EC2 (the t3.micro jump host) | Gets an inline `rtrrl-control-plane` policy + `AmazonSSMManagedInstanceCore`: submit/monitor Batch jobs, read/write the S3 artifact bucket, push/pull the ECR image, read CloudWatch logs, SSM Session Manager |
| `rtrrl-ecs-instance-role` | EC2 (Batch compute instances) | Runs the ECS agent on the c7a.xlarge nodes; pulls the image from ECR, registers with ECS (`AmazonEC2ContainerServiceforEC2Role`), + SSM for debugging |
| `rtrrl-batch-job-role` | ECS tasks | What the **training container** can do: read/write the S3 bucket, write CloudWatch logs |

Auto / optional:

- **`AWSServiceRoleForBatch`** (Batch service-linked role) is created automatically
  on first compute-environment creation.
- **`AmazonEC2SpotFleetTaggingRole`** is only needed if the compute environment uses
  Spot; set `USE_SPOT=true` in `setup-iam.sh` to create it.
- A separate **execution role** is not required for the EC2 launch type — image pull
  is handled by `rtrrl-ecs-instance-role`.

## Why we attach to the existing `controller` role

The jump host already has an instance profile (`controller`), and an EC2 instance can
only have **one** instance profile. So instead of creating/associating a new profile,
`setup-iam.sh` attaches the control-plane permissions to `controller` directly. This
needs no stop/start and avoids profile conflicts.

## Usage

1. Edit the variables at the top of `setup-iam.sh` (`BUCKET`, `ECR_REPO`, `REGION`,
   `JUMP_ROLE`, `USE_SPOT`).
2. Run with **admin/IAM-capable credentials** (your local AWS profile or CloudShell),
   not from the jump host's own role:

   ```bash
   ./setup-iam.sh
   ```

## Least privilege notes

- S3 access is scoped to the single artifact bucket (`__BUCKET__` and `/*`).
- ECR push/pull is scoped to the single repo; only `ecr:GetAuthorizationToken` is `*`
  (API requirement).
- `iam:PassRole` on the jump host is restricted to the Batch job role and the ECS
  instance role ARNs.
- Batch / CloudWatch describe/read actions use `*` because they are not usefully
  resource-scopable here; tighten later if needed.
