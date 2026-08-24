#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "Usage: $0 INPUT.tar.gz OUTPUT.tar.gz PROJECT_NAME START_ITERATION" >&2
    exit 2
fi

input_archive=$1
output_archive=$2
project_name=$3
start_iteration=$4

if [[ ! -r "$input_archive" ]]; then
    echo "Cannot read input archive: $input_archive" >&2
    exit 2
fi
if [[ "$input_archive" != *.tar.gz || "$output_archive" != *.tar.gz ]]; then
    echo "Input and output names must end in .tar.gz" >&2
    exit 2
fi
if [[ "$input_archive" == "$output_archive" ]]; then
    echo "Input and output archives must have different names." >&2
    exit 2
fi
if [[ ! "$project_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Unsafe project name: $project_name" >&2
    exit 2
fi
if [[ ! "$start_iteration" =~ ^[0-9]+$ ]]; then
    echo "START_ITERATION must be a non-negative integer." >&2
    exit 2
fi

output_parent=$(dirname "$output_archive")
if [[ ! -d "$output_parent" || ! -w "$output_parent" ]]; then
    echo "Output directory is missing or not writable: $output_parent" >&2
    exit 2
fi

job_scratch=${_CONDOR_SCRATCH_DIR:-/tmp}
launcher_directory=$(cd "$(dirname "$0")" && pwd -P)
extract_root="$job_scratch/archive-work"
local_input="$job_scratch/input.tar.gz"
local_output="$job_scratch/output.tar.gz"
member_list="$job_scratch/archive-members.txt"
runtime_config="$job_scratch/runtime-config.yml"
project_directory="$extract_root/$project_name"
training_directory="$project_directory/warp_tiltseries"

mkdir -p "$extract_root"
cp "$input_archive" "$local_input"
tar -tzf "$local_input" > "$member_list"
while IFS= read -r member; do
    case "$member" in
        /*|..|../*|*/..|*/../*)
            echo "Unsafe path in input archive: $member" >&2
            exit 2
            ;;
    esac
done < "$member_list"

tar -xzf "$local_input" -C "$extract_root"
if [[ ! -d "$project_directory" ]]; then
    echo "Archive must contain a top-level $project_name/ directory." >&2
    exit 2
fi

config_file="$project_directory/config.yml"
if [[ ! -r "$config_file" ]]; then
    config_file="$project_directory/config.yaml"
fi
if [[ ! -r "$config_file" ]]; then
    echo "Cannot find config.yml or config.yaml in $project_directory" >&2
    exit 2
fi
if [[ ! -d "$training_directory" ]]; then
    echo "Missing training directory: $training_directory" >&2
    exit 2
fi

shopt -s nullglob
working_xmls=("$training_directory"/*.xml)
prepared_stacks=("$training_directory"/tiltstack/*/*.st)
if (( ${#working_xmls[@]} == 0 )); then
    echo "No top-level Warp XML files found in $training_directory" >&2
    exit 2
fi
if (( ${#prepared_stacks[@]} == 0 )); then
    echo "No prepared tilt stack found under $training_directory/tiltstack" >&2
    echo "Create it once with --prepare-stacks before using archive mode." >&2
    exit 2
fi
for stack in "${prepared_stacks[@]}"; do
    if [[ ! -s "$stack" ]]; then
        echo "Prepared tilt stack is empty: $stack" >&2
        exit 2
    fi
done

if (( start_iteration > 0 )); then
    iteration_directory="$training_directory/iter$start_iteration"
    iteration_xmls=("$iteration_directory"/*.xml)
    if [[ ! -s "$iteration_directory/model.ckpt" || ${#iteration_xmls[@]} == 0 ]]; then
        echo "Resume iteration $start_iteration lacks model.ckpt or XML snapshot." >&2
        exit 2
    fi
fi

miss_alignment_python=${MISS_ALIGNMENT_PYTHON:-/opt/miss-alignment/bin/python}
miss_alignment_command=${MISS_ALIGNMENT_COMMAND:-/opt/miss-alignment/bin/miss-alignment}

"$miss_alignment_python" \
    "$launcher_directory/rewrite_miss_alignment_config.py" \
    "$config_file" \
    "$runtime_config" \
    "$training_directory"

export TMPDIR="$job_scratch/miss-alignment-tmp"
export TORCH_HOME="$job_scratch/torch"
export TORCHINDUCTOR_CACHE_DIR="$job_scratch/torchinductor"
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
export PATH="/opt/miss-alignment/bin:$PATH"
export LD_LIBRARY_PATH="/opt/miss-alignment/lib:${LD_LIBRARY_PATH:-}"
mkdir -p "$TMPDIR" "$TORCH_HOME" "$TORCHINDUCTOR_CACHE_DIR"

echo "Input archive: $input_archive"
echo "Local project: $project_directory"
echo "Output archive: $output_archive"
echo "Start iteration: $start_iteration"
echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<not set>}"

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
"$miss_alignment_command" train \
    --config-file "$runtime_config" \
    --training-devices 0 \
    --reconstruction-devices 0,0,0 \
    --dataloaders-per-trainer 5 \
    --start-at-iteration "$start_iteration" &
child_pid=$!
wait "$child_pid"
train_status=$?
set -e
trap - TERM INT

if (( termination_requested != 0 && train_status == 0 )); then
    train_status=143
fi

echo "Packaging project after MissAlignment exit status $train_status"
tar -czf "$local_output" -C "$extract_root" "$project_name"

# Copy to a temporary name on staging, then rename on the same filesystem so
# readers never mistake an incomplete copy for the finished result archive.
partial_output="${output_archive}.partial.$$"
cp "$local_output" "$partial_output"
mv -f "$partial_output" "$output_archive"
echo "Saved archive: $output_archive"

exit "$train_status"
