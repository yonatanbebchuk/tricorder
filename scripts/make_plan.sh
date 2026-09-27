#!/usr/bin/env bash
# Compatibility wrapper for the plan stage:  scripts/make_plan.sh <env_id> <scan3d asset id>
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec "$ROOT/.venv/bin/python" -m tricorder.pipeline new-run "${1:?env_id}" plan --asset "${2:?asset_id}" --px-per-m "${PXM:-50}" --start
