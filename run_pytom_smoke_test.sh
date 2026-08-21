#!/usr/bin/env bash
set -euo pipefail

job_scratch=${_CONDOR_SCRATCH_DIR:-/tmp}
export TMPDIR="$job_scratch/pytom-smoke-tmp"
export CUPY_CACHE_DIR="$job_scratch/pytom-cupy-cache"
export MPLCONFIGDIR="$job_scratch/pytom-matplotlib"
mkdir -p "$TMPDIR" "$CUPY_CACHE_DIR" "$MPLCONFIGDIR"

echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<not set>}"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
else
    echo "nvidia-smi is not available inside this container; continuing with the CuPy CUDA test."
fi

/opt/pytom-match-pick/bin/python - <<'PY'
from importlib.metadata import version

import cupy as cp
import pytom_tm

print(f"pytom-match-pick: {version('pytom-match-pick')}")
print(f"CuPy: {cp.__version__}")
print(f"CUDA runtime: {cp.cuda.runtime.runtimeGetVersion()}")
print(f"GPU count visible to job: {cp.cuda.runtime.getDeviceCount()}")
assert cp.cuda.runtime.getDeviceCount() >= 1, "CuPy cannot see the assigned GPU"

device = cp.cuda.Device(0)
print(f"GPU 0 compute capability: {device.compute_capability}")
a = cp.arange(1024, dtype=cp.float32).reshape(32, 32)
b = cp.fft.fftn(a)
assert bool(cp.all(cp.isfinite(b)))
print("CuPy allocation and FFT: OK")
PY

command -v pytom_match_template.py
pytom_match_template.py --help >/dev/null
echo "PyTom Match Pick and CUDA smoke test passed."
