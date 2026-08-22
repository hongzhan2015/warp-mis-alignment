#!/usr/bin/env bash
set -euo pipefail

echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<not set>}"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
else
    echo "nvidia-smi is not available inside this container; continuing with the CUDA runtime test."
fi

command -v GCtfFind
GCtfFind --version
GCtfFind --help >/dev/null

command -v gctffind_cuda_probe
gctffind_cuda_probe

echo "GCtfFind and CUDA smoke test passed."
