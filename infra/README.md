# RTRRL AWS infra

Minimal pipeline to run RTRRL / PPO training on **AWS Batch** (EC2-backed,
CPU, e.g. `c7a.xlarge`), with **Aim** metrics streamed live to the Aim server on
the jump host.

Scope note: checkpoint S3 sync and Aim run-resume are intentionally **not**
wired up yet. Jobs run on on-demand EC2 (not interrupted), so getting a run to
go end-to-end is the current priority. The resume design can be added later.

## Layout

```
infra/
├── env.sh                 # shared config (edit me first)
├── build-and-push.sh      # build CPU image -> push to ECR
├── submit.sh              # submit one training run (per config)
├── docker/
│   ├── Dockerfile         # CPU image: uv-installed deps + AWS CLI
│   └── entrypoint.sh      # decodes CONFIG_B64 -> /tmp/run-config.yml, runs cmd
├── batch/
│   └── create-batch.sh    # compute environment + queue + job definition
├── iam/                   # IAM roles/policies (see iam/README.md)
└── monitoring/            # CloudWatch agent config for the jump host
```

## One-time setup order

1. **IAM** — `infra/iam/setup-iam.sh` (creates `rtrrl-ecs-instance-role`,
   `rtrrl-batch-job-role`; control-plane perms already on `controller`).
2. **S3 bucket** (only needed later for checkpoints; not required to run):
   ```bash
   aws s3api create-bucket --bucket "$S3_BUCKET" --region eu-north-1 \
     --create-bucket-configuration LocationConstraint=eu-north-1
   ```
3. **Edit `infra/env.sh`** — set `SUBNET_IDS`, `SECURITY_GROUP_ID`, and
   `AIM_SERVER` (jump host private IP), confirm `ECR_REPO`, `INSTANCE_TYPE`.
4. **Build + push image**:
   ```bash
   infra/build-and-push.sh
   ```
5. **Create Batch resources**:
   ```bash
   infra/batch/create-batch.sh
   ```

## Run training

Start the Aim server on the jump host (once), bound so the compute subnet can
reach it on 53800:

```bash
uv run aim server --repo logs/aim/.aim --host 0.0.0.0 --port 53800
```

Submit runs (one per config; loop for sweeps):

```bash
# RTRRL
infra/submit.sh --config config/rtrrl_brax_hopper_paral1.yml

# PPO baseline
infra/submit.sh --entry ppo_baseline.py --config config/ppo_hopper_default_2m.yml

# Override params without a new config file (parallel scale etc.)
infra/submit.sh --config config/rtrrl_brax_hopper_paral1.yml --name hopper_b8 \
  -- --batch_size 8 --seed 1
```

Watch a job:

```bash
aws batch describe-jobs --region eu-north-1 --jobs <jobId> \
  --query "jobs[0].{status:status,reason:statusReason}"
```

## Networking prerequisites

- The compute environment subnet must be able to pull from **ECR** and reach
  **S3** — if it is a private subnet, add a NAT gateway or VPC endpoints
  (S3 gateway endpoint + ECR/ECR-API/logs interface endpoints).
- The **security group** must allow the compute instances to reach the jump
  host on TCP **53800** (Aim), and allow egress for ECR/S3.

## Different configs

Configs live in `config/` but are **not** baked into the image (see
`.dockerignore`). At submit time `submit.sh` base64-encodes the chosen YAML into
the `CONFIG_B64` env var; the container entrypoint decodes it to
`/tmp/run-config.yml`, which the training command reads via `--config_path`.

This means:
- Editing or adding a config needs **no image rebuild** — just re-submit.
- Each job carries the exact config it ran with (visible in the job's overrides).
- Pick one per run with `--config`; tweak individual params with trailing
  `-- --key value` overrides.

Configs are tiny YAML, so inlining them is simpler than S3. (S3 is reserved for
checkpoints later, where payloads are large.)
