#!/usr/bin/env bash
# Compatibility wrapper for the plan stage:  scripts/make_plan.sh <scan_id> <run_id>
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec "$ROOT/.venv/bin/python" -m scanner.pipeline plan "${1:?scan_id}" "${2:?run_id}" --px-per-m "${PXM:-50}"
