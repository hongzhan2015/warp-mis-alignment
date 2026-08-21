#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 PROJECT_DIRECTORY ITERATION [ANGPIX]" >&2
    echo "Example: $0 /staging/USER/project 8 12" >&2
    exit 2
fi

project_directory=$1
iteration=${2#iter}
reconstruction_angpix=${3:-12}

if [[ ! "$iteration" =~ ^[0-9]+$ ]]; then
    echo "Iteration must be an integer or iterN: $2" >&2
    exit 2
fi
if [[ ! "$reconstruction_angpix" =~ ^[0-9]+([.][0-9]+)?$ || \
      "$reconstruction_angpix" == 0 ]]; then
    echo "Reconstruction pixel size must be positive: $reconstruction_angpix" >&2
    exit 2
fi
if [[ ! -d "$project_directory" ]]; then
    echo "Project directory does not exist: $project_directory" >&2
    exit 2
fi

project_directory=$(cd "$project_directory" && pwd -P)
settings_file="$project_directory/warp_tiltseries.settings"
iteration_name="iter$iteration"
iteration_directory="$project_directory/warp_tiltseries/$iteration_name"

if [[ ! -r "$settings_file" ]]; then
    echo "Cannot read Warp settings: $settings_file" >&2
    exit 2
fi
if [[ ! -d "$iteration_directory" ]]; then
    echo "MissAlignment iteration directory does not exist: $iteration_directory" >&2
    exit 2
fi

shopt -s nullglob
iteration_xml=("$iteration_directory"/*.xml)
if (( ${#iteration_xml[@]} == 0 )); then
    echo "No Warp XML files found in $iteration_directory" >&2
    exit 2
fi

job_scratch=${_CONDOR_SCRATCH_DIR:-/tmp}
export TMPDIR="$job_scratch/warp-reconstruction-tmp"
export PATH="/opt/warp/bin:$PATH"
export LD_LIBRARY_PATH="/opt/warp/lib:${LD_LIBRARY_PATH:-}"
export DOTNET_ROOT=/opt/warp/share/dotnet

# Warp's parent and GPU worker communicate over HTTP on localhost.
loopback_hosts="localhost,127.0.0.1,::1"
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}$loopback_hosts"
export no_proxy="${no_proxy:+$no_proxy,}$loopback_hosts"

# Launch the worker from small local scratch to avoid Warp's network-filesystem
# watcher delaying startup beyond its 20-second connection timeout.
worker_launch_directory="$job_scratch/warp-reconstruction-worker"
mkdir -p "$TMPDIR" "$worker_launch_directory"

save_worker_diagnostics() {
    local diagnostics_directory="$iteration_directory/warp_worker_diagnostics"
    local diagnostic_files=("$worker_launch_directory"/worker*.out "$worker_launch_directory"/worker*.err)
    if (( ${#diagnostic_files[@]} > 0 )); then
        mkdir -p "$diagnostics_directory"
        cp -f -- "${diagnostic_files[@]}" "$diagnostics_directory/" || true
    fi
}
trap save_worker_diagnostics EXIT

cd "$worker_launch_directory"

echo "Project: $project_directory"
echo "MissAlignment iteration: $iteration_name"
echo "Iteration XML files: ${#iteration_xml[@]}"
echo "Reconstruction pixel size: $reconstruction_angpix A"
echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<not set>}"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
else
    echo "nvidia-smi is not available inside this container; continuing without it."
fi

WarpTools ts_reconstruct \
    --settings "$settings_file" \
    --input_processing "$iteration_directory" \
    --angpix "$reconstruction_angpix"

echo "Generated miss-aligned reconstructions:"
find "$iteration_directory/reconstruction" -maxdepth 1 -type f -print
echo "Miss-aligned Warp reconstruction completed successfully."
