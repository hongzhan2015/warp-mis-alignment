#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 CONFIG_YAML [START_ITERATION]" >&2
    exit 2
fi

config_file=$1
start_iteration=${2:-0}

if [[ ! -r "$config_file" ]]; then
    echo "Cannot read config file: $config_file" >&2
    exit 2
fi

# MissAlignment creates its own workers. With one large GPU, all logical device
# references are 0; do not replace HTCondor's CUDA_VISIBLE_DEVICES value.
job_scratch=${_CONDOR_SCRATCH_DIR:-/tmp}
export TMPDIR="$job_scratch/miss-alignment-tmp"
export TORCH_HOME="$job_scratch/torch"
export TORCHINDUCTOR_CACHE_DIR="$job_scratch/torchinductor"
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
export PATH="/opt/miss-alignment/bin:$PATH"
export LD_LIBRARY_PATH="/opt/miss-alignment/lib:${LD_LIBRARY_PATH:-}"
mkdir -p "$TMPDIR" "$TORCH_HOME" "$TORCHINDUCTOR_CACHE_DIR"

echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<not set>}"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
else
    echo "nvidia-smi is not available inside this container; continuing without it."
fi

exec /opt/miss-alignment/bin/miss-alignment train \
    --config-file "$config_file" \
    --training-devices 0 \
    --reconstruction-devices 0,0,0 \
    --dataloaders-per-trainer 5 \
    --start-at-iteration "$start_iteration" \
    --prepare-stacks 10.0
