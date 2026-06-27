#!/usr/bin/env bash
# Submit one training run to AWS Batch.
#
# Usage:
#   infra/submit.sh --config config/rtrrl_brax_hopper_paral1.yml [options] [-- extra args]
#
# Options:
#   --config PATH     YAML config to run (required)
#   --entry FILE      entry script: rtrrl.py (default) or ppo_baseline.py
#   --name NAME       run name (default: derived from the config filename)
#   --no-aim          do not log to the jump-host Aim server
#   -- ...            everything after -- is passed verbatim as CLI overrides
#                     to the training script (e.g. -- --batch_size 8 --seed 1)
#
# Each run gets a unique --name => its own Aim run; submit in a loop for sweeps.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/env.sh"

ENTRY="rtrrl.py"
CONFIG=""
NAME=""
USE_AIM="true"
EXTRA=()

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --entry)  ENTRY="$2"; shift 2 ;;
    --name)   NAME="$2"; shift 2 ;;
    --no-aim) USE_AIM="false"; shift ;;
    --) shift; EXTRA=("$@"); break ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[ -z "${CONFIG}" ] && { echo "ERROR: --config is required" >&2; exit 1; }

# Run name: default to the config basename (sanitized).
if [ -z "${NAME}" ]; then
  NAME="$(basename "${CONFIG}" .yml | tr -c 'A-Za-z0-9_.-' '_')"
fi

[ -f "${CONFIG}" ] || { echo "ERROR: config not found: ${CONFIG}" >&2; exit 1; }

# The config is NOT baked into the image. We inline it here: base64-encode the
# YAML and pass it as the CONFIG_B64 env var; the container entrypoint decodes it
# to /tmp/run-config.yml, which the training command reads via --config_path.
# base64 -w0 emits a single JSON-safe line ([A-Za-z0-9+/=], no quotes/newlines).
CONFIG_B64=$(base64 -w0 "${CONFIG}")

# Build the training command (reads the decoded config inside the container).
CMD=(python "${ENTRY}" --config_path /tmp/run-config.yml)
if [ "${USE_AIM}" = "true" ]; then
  CMD+=(--logging aim --log_repo "${AIM_SERVER}")
fi
CMD+=("${EXTRA[@]}")

# JSON array for the container command override.
CMD_JSON=$(printf '"%s",' "${CMD[@]}"); CMD_JSON="[${CMD_JSON%,}]"

echo "Run name : ${NAME}"
echo "Config   : ${CONFIG}"
echo "Command  : ${CMD[*]}"

aws batch submit-job \
  --region "${REGION}" \
  --job-name "${NAME}" \
  --job-queue "${JOB_QUEUE}" \
  --job-definition "${JOB_DEF}" \
  --container-overrides "{\"command\": ${CMD_JSON}, \"environment\": [{\"name\": \"CONFIG_B64\", \"value\": \"${CONFIG_B64}\"}]}" \
  --query "{name:jobName, id:jobId}" --output table
