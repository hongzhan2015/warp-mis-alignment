#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
    echo "Usage: $0 TOMOGRAM TEMPLATE MASK DESTINATION PARTICLE_DIAMETER WARP_XML" >&2
    exit 2
fi

tomogram=$1
template=$2
mask=$3
destination=$4
particle_diameter=$5
warp_xml=$6

for input_file in "$tomogram" "$template" "$mask" "$warp_xml"; do
    if [[ ! -r "$input_file" ]]; then
        echo "Cannot read input file: $input_file" >&2
        exit 2
    fi
done
if [[ ! "$particle_diameter" =~ ^[0-9]+([.][0-9]+)?$ || \
      "$particle_diameter" == 0 ]]; then
    echo "Particle diameter must be a positive value in Angstrom: $particle_diameter" >&2
    exit 2
fi

job_scratch=${_CONDOR_SCRATCH_DIR:-/tmp}
export CONDA_PREFIX=${CONDA_PREFIX:-/opt/pytom-match-pick}
export CUDA_PATH=${CUDA_PATH:-$CONDA_PREFIX/targets/x86_64-linux}
export TMPDIR="$job_scratch/pytom-match-tmp"
export CUPY_CACHE_DIR="$job_scratch/pytom-cupy-cache"
export MPLCONFIGDIR="$job_scratch/pytom-matplotlib"
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
mkdir -p "$TMPDIR" "$CUPY_CACHE_DIR" "$MPLCONFIGDIR" "$destination"

echo "Tomogram: $tomogram"
echo "Template: $template"
echo "Mask: $mask"
echo "Warp XML: $warp_xml"
echo "Destination: $destination"
echo "Particle diameter: $particle_diameter A"
echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<not set>}"

/opt/pytom-match-pick/bin/python - <<'PY'
import cupy as cp

assert cp.cuda.runtime.getDeviceCount() >= 1, "CuPy cannot see the assigned GPU"
print(f"CuPy: {cp.__version__}")
print(f"CUDA runtime: {cp.cuda.runtime.runtimeGetVersion()}")
print(f"GPU 0 compute capability: {cp.cuda.Device(0).compute_capability}")
PY

exec pytom_match_template.py \
    --tomogram "$tomogram" \
    --template "$template" \
    --mask "$mask" \
    --destination "$destination" \
    --particle-diameter "$particle_diameter" \
    --warp-xml-file "$warp_xml" \
    --volume-split 2 2 1 \
    --gpu-ids 0
