#!/usr/bin/env bash
set -euo pipefail

echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<not set>}"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi
else
    echo "nvidia-smi is not available inside this container; continuing with the PyTorch CUDA test."
fi

/opt/miss-alignment/bin/python - <<'PY'
import torch
print(f"PyTorch: {torch.__version__}")
print(f"CUDA runtime: {torch.version.cuda}")
print(f"CUDA available: {torch.cuda.is_available()}")
assert torch.cuda.is_available(), "PyTorch cannot see the assigned GPU"
print(f"GPU count visible to job: {torch.cuda.device_count()}")
print(f"GPU 0: {torch.cuda.get_device_name(0)}")
PY

command -v WarpTools
command -v miss-alignment
LD_LIBRARY_PATH="/opt/warp/lib:${LD_LIBRARY_PATH:-}" \
    /opt/warp/bin/WarpTools --help >/dev/null
miss-alignment --help >/dev/null
echo "Warp, MissAlignment, and CUDA smoke test passed."
