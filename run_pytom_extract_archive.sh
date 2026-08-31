#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
    echo "Usage: $0 INPUT.tar.gz OUTPUT.tar.gz TARGET TS_N CUTOFF MAX_PARTICLES" >&2
    echo "CUTOFF may be a number from 0 to 1, or 'auto'." >&2
    exit 2
fi

input_archive=$1
output_archive=$2
target=$3
series_name=$4
cutoff=$5
max_particles=$6

if [[ ! -r "$input_archive" ]]; then
    echo "Cannot read input archive: $input_archive" >&2
    exit 2
fi
if [[ "$input_archive" != *.tar.gz || "$output_archive" != *.tar.gz ]]; then
    echo "Input and output archives must end in .tar.gz." >&2
    exit 2
fi
if [[ ! "$target" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "TARGET may contain only letters, numbers, dot, underscore, and dash: $target" >&2
    exit 2
fi
if [[ ! "$series_name" =~ ^TS_[0-9]+$ ]]; then
    echo "Series name must look like TS_N: $series_name" >&2
    exit 2
fi
if [[ ! "$max_particles" =~ ^[1-9][0-9]*$ ]]; then
    echo "MAX_PARTICLES must be a positive integer: $max_particles" >&2
    exit 2
fi
if [[ "$cutoff" != auto ]]; then
    if [[ ! "$cutoff" =~ ^(0([.][0-9]+)?|1([.]0+)?)$ ]]; then
        echo "CUTOFF must be between 0 and 1, or 'auto': $cutoff" >&2
        exit 2
    fi
fi

output_parent=$(dirname "$output_archive")
if [[ ! -d "$output_parent" || ! -w "$output_parent" ]]; then
    echo "Output directory is missing or not writable: $output_parent" >&2
    exit 2
fi

job_scratch=${_CONDOR_SCRATCH_DIR:-/tmp}
work_directory="$job_scratch/pytom-extract-work"
result_name="output_extracted_${target}_${series_name}"
result_directory="$job_scratch/$result_name"
local_archive="$job_scratch/${result_name}.tar.gz"
mkdir -p "$work_directory" "$result_directory"

echo "Testing and unpacking: $input_archive"
gzip -t "$input_archive"
tar -xzf "$input_archive" -C "$work_directory"

job_files=()
while IFS= read -r -d '' path; do
    job_files+=("$path")
done < <(find "$work_directory" -type f -name '*_job.json' -print0)
if (( ${#job_files[@]} != 1 )); then
    echo "Expected exactly one *_job.json in the archive; found ${#job_files[@]}." >&2
    find "$work_directory" -type f -name '*_job.json' -print >&2
    exit 2
fi
job_file=${job_files[0]}
job_directory=$(dirname "$job_file")

score_files=()
while IFS= read -r -d '' path; do
    score_files+=("$path")
done < <(find "$job_directory" -maxdepth 1 -type f -name '*_scores.mrc' -print0)
angle_files=()
while IFS= read -r -d '' path; do
    angle_files+=("$path")
done < <(find "$job_directory" -maxdepth 1 -type f -name '*_angles.mrc' -print0)
if (( ${#score_files[@]} != 1 || ${#angle_files[@]} != 1 )); then
    echo "The matching archive must contain exactly one score MRC and one angle MRC beside the job JSON." >&2
    echo "Score files: ${#score_files[@]}; angle files: ${#angle_files[@]}" >&2
    exit 2
fi

# Matching ran in an earlier Condor scratch directory. Rewrite output_dir and
# any paths below it so the archived job JSON points at this job's unpacked copy.
pytom_python=${PYTOM_PYTHON:-/opt/pytom-match-pick/bin/python}
cp "$job_file" "$result_directory/original_job.json"
"$pytom_python" - "$job_file" "$job_directory" <<'PY'
import json
from pathlib import Path
import sys

job_path = Path(sys.argv[1])
new_output = str(Path(sys.argv[2]).resolve())
data = json.loads(job_path.read_text())
old_output = data.get("output_dir")
if not isinstance(old_output, str) or not old_output:
    raise ValueError("Job JSON does not contain a usable output_dir")

def relocate(value):
    if isinstance(value, dict):
        return {key: relocate(item) for key, item in value.items()}
    if isinstance(value, list):
        return [relocate(item) for item in value]
    if isinstance(value, str) and (value == old_output or value.startswith(old_output + "/")):
        return new_output + value[len(old_output):]
    return value

data = relocate(data)
data["output_dir"] = new_output
job_path.write_text(json.dumps(data, indent=2) + "\n")
print(f"Relocated PyTom output_dir: {old_output} -> {new_output}")
PY

export CONDA_PREFIX=${CONDA_PREFIX:-/opt/pytom-match-pick}
export CUDA_PATH=${CUDA_PATH:-$CONDA_PREFIX/targets/x86_64-linux}
export TMPDIR="$job_scratch/pytom-extract-tmp"
export CUPY_CACHE_DIR="$job_scratch/pytom-cupy-cache"
export MPLCONFIGDIR="$job_scratch/pytom-matplotlib"
export OMP_NUM_THREADS=${OMP_NUM_THREADS:-4}
export MKL_NUM_THREADS=${MKL_NUM_THREADS:-4}
mkdir -p "$TMPDIR" "$CUPY_CACHE_DIR" "$MPLCONFIGDIR"

extract_command=${PYTOM_EXTRACT_COMMAND:-pytom_extract_candidates.py}
extract_arguments=(
    --job-file "$job_file"
    --number-of-particles "$max_particles"
)
if [[ "$cutoff" != auto ]]; then
    extract_arguments+=(--cut-off "$cutoff")
fi

echo "Target: $target"
echo "Series: $series_name"
echo "Cutoff: $cutoff"
echo "Maximum particles: $max_particles"
echo "Job JSON: $job_file"
"$extract_command" "${extract_arguments[@]}"

particle_stars=()
while IFS= read -r -d '' path; do
    particle_stars+=("$path")
done < <(find "$job_directory" -maxdepth 1 -type f -name '*_particles.star' -print0)
if (( ${#particle_stars[@]} != 1 )); then
    echo "Expected exactly one *_particles.star after extraction; found ${#particle_stars[@]}." >&2
    exit 2
fi

cp "${particle_stars[0]}" "$result_directory/"
extraction_graphs=()
while IFS= read -r -d '' path; do
    extraction_graphs+=("$path")
done < <(find "$job_directory" -maxdepth 1 -type f -name '*_extraction_graph.svg' -print0)
if (( ${#extraction_graphs[@]} == 1 )); then
    cp "${extraction_graphs[0]}" "$result_directory/"
fi
cp "$job_file" "$result_directory/relocated_job.json"
printf '%s\n' \
    "target=$target" \
    "series=$series_name" \
    "input_archive=$input_archive" \
    "cutoff=$cutoff" \
    "max_particles=$max_particles" \
    > "$result_directory/extraction_parameters.txt"

tar -czf "$local_archive" -C "$job_scratch" "$result_name"
partial_output="${output_archive}.partial.$$"
cp "$local_archive" "$partial_output"
mv -f "$partial_output" "$output_archive"

echo "Saved extraction archive: $output_archive"
echo "Extracted files:"
find "$result_directory" -maxdepth 1 -type f -print
