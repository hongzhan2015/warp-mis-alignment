#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 8 ]]; then
    echo "Usage: $0 TOMOGRAM TEMPLATE MASK WARP_XML OUTPUT.tar.gz SERIES_NAME PARTICLE_DIAMETER MAX_PARTICLES" >&2
    exit 2
fi

tomogram=$1
template=$2
mask=$3
warp_xml=$4
output_archive=$5
series_name=$6
particle_diameter=$7
max_particles=$8

for input_file in "$tomogram" "$template" "$mask" "$warp_xml"; do
    if [[ ! -r "$input_file" ]]; then
        echo "Cannot read input file: $input_file" >&2
        exit 2
    fi
done
if [[ "$output_archive" != *.tar.gz ]]; then
    echo "Output archive must end in .tar.gz: $output_archive" >&2
    exit 2
fi
if [[ ! "$series_name" =~ ^TS_[0-9]+$ ]]; then
    echo "SERIES_NAME must look like TS_N: $series_name" >&2
    exit 2
fi
if [[ ! "$particle_diameter" =~ ^[0-9]+([.][0-9]+)?$ ]] || \
   ! awk -v value="$particle_diameter" 'BEGIN { exit !(value > 0) }'; then
    echo "PARTICLE_DIAMETER must be a positive value in Angstrom: $particle_diameter" >&2
    exit 2
fi
if [[ ! "$max_particles" =~ ^[1-9][0-9]*$ ]]; then
    echo "MAX_PARTICLES must be a positive integer: $max_particles" >&2
    exit 2
fi

output_parent=$(dirname "$output_archive")
if [[ ! -d "$output_parent" || ! -w "$output_parent" ]]; then
    echo "Output directory is missing or not writable: $output_parent" >&2
    exit 2
fi

job_scratch=${_CONDOR_SCRATCH_DIR:-/tmp}
input_directory="$job_scratch/pytom-inputs"
result_name="output_picker_${series_name}"
result_directory="$job_scratch/$result_name"
local_archive="$job_scratch/${result_name}.tar.gz"

mkdir -p "$input_directory" "$result_directory"
local_tomogram="$input_directory/$(basename "$tomogram")"
local_template="$input_directory/$(basename "$template")"
local_mask="$input_directory/$(basename "$mask")"
local_xml="$input_directory/$(basename "$warp_xml")"
cp "$tomogram" "$local_tomogram"
cp "$template" "$local_template"
cp "$mask" "$local_mask"
cp "$warp_xml" "$local_xml"

export CONDA_PREFIX=${CONDA_PREFIX:-/opt/pytom-match-pick}
export CUDA_PATH=${CUDA_PATH:-$CONDA_PREFIX/targets/x86_64-linux}
export TMPDIR="$job_scratch/pytom-match-tmp"
export CUPY_CACHE_DIR="$job_scratch/pytom-cupy-cache"
export MPLCONFIGDIR="$job_scratch/pytom-matplotlib"
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
mkdir -p "$TMPDIR" "$CUPY_CACHE_DIR" "$MPLCONFIGDIR"

pytom_python=${PYTOM_PYTHON:-/opt/pytom-match-pick/bin/python}
pytom_match_command=${PYTOM_MATCH_COMMAND:-pytom_match_template.py}
pytom_extract_command=${PYTOM_EXTRACT_COMMAND:-pytom_extract_candidates.py}

if [[ "${SKIP_MRC_VALIDATION:-0}" != 1 ]]; then
    "$pytom_python" - "$local_tomogram" "$local_template" "$local_mask" <<'PY'
from pathlib import Path
import sys

import mrcfile


def describe(path_string: str) -> tuple[Path, tuple[int, ...], float]:
    path = Path(path_string)
    with mrcfile.open(path, mode="r", permissive=True) as mrc:
        shape = tuple(int(value) for value in mrc.data.shape)
        voxel_size = float(mrc.voxel_size.x)
    print(f"{path.name}: shape={shape}, voxel_size={voxel_size:.6g} A")
    return path, shape, voxel_size


_, _, tomogram_voxel = describe(sys.argv[1])
_, template_shape, template_voxel = describe(sys.argv[2])
_, mask_shape, _ = describe(sys.argv[3])

if template_shape != mask_shape:
    raise ValueError(
        f"Template and mask shapes differ: {template_shape} versus {mask_shape}"
    )
if tomogram_voxel <= 0 or template_voxel <= 0:
    raise ValueError("Tomogram and template MRC headers must contain voxel sizes")
relative_difference = abs(tomogram_voxel - template_voxel) / tomogram_voxel
if relative_difference > 0.01:
    raise ValueError(
        f"Template voxel size {template_voxel:g} A does not match "
        f"tomogram voxel size {tomogram_voxel:g} A"
    )
PY
fi

echo "Tomogram: $tomogram"
echo "Template: $template"
echo "Mask: $mask"
echo "Warp XML: $warp_xml"
echo "Series: $series_name"
echo "Particle diameter: $particle_diameter A"
echo "Maximum extracted candidates: $max_particles"
echo "Local results: $result_directory"
echo "Output archive: $output_archive"
echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<not set>}"

if [[ "${SKIP_CUDA_VALIDATION:-0}" != 1 ]]; then
    "$pytom_python" - <<'PY'
import cupy as cp

assert cp.cuda.runtime.getDeviceCount() >= 1, "CuPy cannot see the assigned GPU"
print(f"CuPy: {cp.__version__}")
print(f"CUDA runtime: {cp.cuda.runtime.runtimeGetVersion()}")
print(f"GPU 0 compute capability: {cp.cuda.Device(0).compute_capability}")
PY
fi

printf '%s\n' \
    "series=$series_name" \
    "tomogram=$tomogram" \
    "template=$template" \
    "mask=$mask" \
    "warp_xml=$warp_xml" \
    "particle_diameter_angstrom=$particle_diameter" \
    "max_particles=$max_particles" \
    "volume_split=2 2 2" \
    "random_phase_correction=true" \
    "rng_seed=45132" \
    > "$result_directory/run_parameters.txt"

child_pid=""
termination_requested=0
terminate_child() {
    termination_requested=1
    if [[ -n "$child_pid" ]]; then
        kill -TERM "$child_pid" 2>/dev/null || true
    fi
}
trap terminate_child TERM INT

set +e
"$pytom_match_command" \
    --tomogram "$local_tomogram" \
    --template "$local_template" \
    --mask "$local_mask" \
    --destination "$result_directory" \
    --particle-diameter "$particle_diameter" \
    --warp-xml-file "$local_xml" \
    --volume-split 2 2 2 \
    --random-phase-correction \
    --rng-seed 45132 \
    --gpu-ids 0 &
child_pid=$!
wait "$child_pid"
match_status=$?
set -e
trap - TERM INT

if (( termination_requested != 0 && match_status == 0 )); then
    match_status=143
fi

overall_status=$match_status
if (( match_status == 0 )); then
    shopt -s nullglob
    job_files=("$result_directory"/*_job.json)
    if (( ${#job_files[@]} != 1 )); then
        echo "Expected exactly one PyTom job JSON, found ${#job_files[@]}." >&2
        overall_status=2
    else
        set +e
        "$pytom_extract_command" \
            --job-file "${job_files[0]}" \
            --number-of-particles "$max_particles" \
            --particle-diameter "$particle_diameter"
        overall_status=$?
        set -e
    fi
else
    echo "Template matching exited with status $match_status; candidate extraction was skipped." >&2
fi

mkdir -p "$result_directory/inputs"
cp "$local_template" "$result_directory/inputs/"
cp "$local_mask" "$result_directory/inputs/"
cp "$local_xml" "$result_directory/inputs/"

echo "Packaging PyTom results after exit status $overall_status"
tar -czf "$local_archive" -C "$job_scratch" "$result_name"
partial_output="${output_archive}.partial.$$"
cp "$local_archive" "$partial_output"
mv -f "$partial_output" "$output_archive"
echo "Saved result archive: $output_archive"

if (( overall_status == 0 )); then
    echo "PyTom output files:"
    find "$result_directory" -maxdepth 2 -type f -print
fi

exit "$overall_status"
