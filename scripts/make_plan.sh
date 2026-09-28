#!/usr/bin/env bash
# Compatibility wrapper for the layout run:  scripts/make_plan.sh <env_id> <model3d asset id> [<measurement recording id> ...]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ENV_ID=${1:?env_id}; ASSET=${2:?asset_id}; shift 2
exec "$ROOT/.venv/bin/python" -m tricorder.pipeline new-run "$ENV_ID" layout --asset "$ASSET" --recordings "$@" --px-per-m "${PXM:-50}" --start
