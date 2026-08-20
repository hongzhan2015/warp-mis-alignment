#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 WarpTools|MTools|... [arguments ...]" >&2
    exit 2
fi

job_scratch=${_CONDOR_SCRATCH_DIR:-/tmp}
export TMPDIR="$job_scratch/warp-tmp"
export PATH="/opt/warp/bin:$PATH"
export LD_LIBRARY_PATH="/opt/warp/lib:${LD_LIBRARY_PATH:-}"
export DOTNET_ROOT=/opt/warp/share/dotnet
mkdir -p "$TMPDIR"

echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<not set>}"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
exec "$@"
