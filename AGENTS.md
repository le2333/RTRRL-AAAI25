# Agent guide

Notes for AI agents working in this repository. Keep this short and current.

## What this is

RTRRL / PPO reinforcement-learning code (JAX/Flax/Brax) plus an `infra/` pipeline
to run training on AWS Batch with metrics streamed to an Aim server on a jump
host. Entry points: `rtrrl.py`, `ppo_baseline.py`. Configs in `config/*.yml`.

## Dependencies: uv, and JAX is pinned — do not bump

- Use **uv** (`uv sync`, `uv run ...`), not pip/poetry.
- **`pyproject.toml` pins `jax==0.5.0` / `jaxlib==0.5.0`. Do NOT upgrade.**
  JAX 0.6+ removed the `jax.jax` self-alias used by `envs/wrappers.py`
  (`jax.jax.tree.map`) and changed array types so `aim` 3.28 can no longer track
  metrics. If you regenerate `uv.lock`, **keep the pin** or training breaks at
  runtime (not at lock/build time).
- Lesson learned: when the upstream training code fails after a dependency
  change, **fix the dependency versions to match upstream** rather than patching
  the training scripts. The only intentional source change for the pipeline is
  one line in `rtrrl.py` (`aim_repo=hparams.log_repo`) needed for remote Aim.

## AWS pipeline (see `infra/README.md` for details)

- **Image build:** GitHub Actions (`.github/workflows/build-image.yml`) builds
  and pushes `rtrrl:cpu` to ECR on push to `main`. No local Docker needed.
- **Configs are injected at submit time, not baked into the image.** `submit.sh`
  base64-encodes the YAML into `CONFIG_B64`; `infra/docker/entrypoint.sh` decodes
  it to `/tmp/run-config.yml`. `config/`, `docs/`, `figures/` are excluded via
  `.dockerignore`. Editing a config needs no rebuild.
- **Submit a run:** `infra/submit.sh --config <cfg> --name <run>`; each `--name`
  is its own run. `--logging aim|wandb|aim+wandb` (default `$LOGGING`). Loop for
  parallel runs.
- **Aim server must be running on the jump host before submitting** (it listens
  on `:53800`; the job connects via `AIM_SERVER` in `infra/env.sh`).
- Batch compute scales to zero when idle; first job after idle waits ~1-2 min.
- IAM: control-plane perms are on the `controller` role (jump host). Some changes
  require updating its inline policies via the AWS console (see `infra/iam/`).

## Logging + W&B sweeps

- `logging_util.with_logger` supports **dual logging**: Aim (local, for
  programmatic/AI reading) + W&B (cloud, for analysis). `MultiLogger` fans calls
  out to both; reads come from the first logger.
- **W&B sweeps** (`infra/sweep.yaml`, `infra/sweep.sh`) do HPO on `ppo_baseline.py`,
  maximizing `eval/best_eval_reward`. Sweep params use **dotted keys**
  (`ppo_overrides.learning_rate`); `with_logger` expands them (`_expand_dotted`)
  and merges into the dataclass so they reach `brax` `ppo.train()`. The sweep
  `command` must NOT include `${args}` (params flow via `wandb.config`, not CLI —
  `simple_parsing` can't parse nested flags). PPO hyperparameters live in the
  free-form `ppo_overrides: dict`, NOT top-level `PPOParams` fields; a flat sweep
  key would be silently dropped by dacite.
- **`WANDB_API_KEY`** is injected into Batch jobs from Secrets Manager
  (`rtrrl/wandb-api-key`) via `rtrrl-batch-execution-role`; never put it in git or
  job overrides. `create-batch.sh` only wires it when `WANDB_SECRET_ARN` is set in
  `infra/env.sh` (re-run after setting it). `wandb.init` uses `mode=disabled` when
  `debug`, else honors `WANDB_MODE` (default online).

## Conventions

- Don't commit unless asked. Don't commit Aim run data (`.aim/`, `logs/aim/`).
- Keep changes minimal and faithful to the upstream paper code.
