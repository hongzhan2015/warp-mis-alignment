#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 || $# -gt 5 ]]; then
    echo "Usage: $0 INPUT.tar.gz OUTPUT.tar.gz PROJECT_NAME ITERATION [ANGPIX]" >&2
    echo "Example: $0 input.tar.gz result.tar.gz output_TS_3_run001 8 12" >&2
    exit 2
fi

input_archive=$1
output_archive=$2
project_name=$3
iteration=${4#iter}
reconstruction_angpix=${5:-12}

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
if [[ ! "$project_name" =~ ^output_(TS_[0-9]+)_run[0-9]+$ ]]; then
    echo "Expected PROJECT_NAME output_TS_N_runNNN, got: $project_name" >&2
    exit 2
fi
series_name=${BASH_REMATCH[1]}
if [[ ! "$iteration" =~ ^[0-9]+$ ]]; then
    echo "ITERATION must be an integer or iterN: $4" >&2
    exit 2
fi
if [[ ! "$reconstruction_angpix" =~ ^[0-9]+([.][0-9]+)?$ ]] || \
   ! awk -v value="$reconstruction_angpix" 'BEGIN { exit !(value > 0) }'; then
    echo "ANGPIX must be a positive number: $reconstruction_angpix" >&2
    exit 2
fi

output_parent=$(dirname "$output_archive")
if [[ ! -d "$output_parent" || ! -w "$output_parent" ]]; then
    echo "Output directory is missing or not writable: $output_parent" >&2
    exit 2
fi

job_scratch=${_CONDOR_SCRATCH_DIR:-/tmp}
launcher_directory=$(cd "$(dirname "$0")" && pwd -P)
extract_root="$job_scratch/warp-reconstruction-archive"
local_input="$job_scratch/reconstruction-input.tar.gz"
local_output="$job_scratch/reconstruction-output.tar.gz"
member_list="$job_scratch/reconstruction-archive-members.txt"
project_directory="$extract_root/$project_name"
processing_directory="$project_directory/warp_tiltseries"
settings_file="$project_directory/warp_tiltseries.settings"
iteration_directory="$processing_directory/iter$iteration"
root_xml="$processing_directory/${series_name}.st.xml"
backup_xml="$root_xml.bak"
iteration_xml="$iteration_directory/${series_name}.st.xml"

mkdir -p "$extract_root"
cp "$input_archive" "$local_input"

if gzip -t "$local_input" 2>/dev/null; then
    input_format=gzip
    tar -tzf "$local_input" > "$member_list"
elif tar -tf "$local_input" >/dev/null 2>&1; then
    input_format=plain
    echo "WARNING: input has a .tar.gz name but is an uncompressed tar archive."
    echo "The result archive will be gzip-compressed."
    tar -tf "$local_input" > "$member_list"
else
    echo "Input is neither a valid gzip-compressed tar nor a plain tar archive." >&2
    exit 2
fi

while IFS= read -r member; do
    case "$member" in
        /*|..|../*|*/..|*/../*)
            echo "Unsafe path in input archive: $member" >&2
            exit 2
            ;;
    esac
done < "$member_list"

if [[ "$input_format" == gzip ]]; then
    tar -xzf "$local_input" -C "$extract_root"
else
    tar -xf "$local_input" -C "$extract_root"
fi

if [[ ! -d "$project_directory" ]]; then
    echo "Archive must contain a top-level $project_name/ directory." >&2
    exit 2
fi
if [[ ! -r "$settings_file" ]]; then
    echo "Cannot read Warp settings: $settings_file" >&2
    exit 2
fi
if [[ ! -r "$root_xml" ]]; then
    echo "Cannot preserve missing original Warp XML: $root_xml" >&2
    exit 2
fi
if [[ ! -r "$iteration_xml" ]]; then
    echo "Cannot read MissAlignment iteration XML: $iteration_xml" >&2
    exit 2
fi

# Preserve the exact XML from the input archive. Do not replace an existing
# backup when resuming from an archive that has already passed this step.
if [[ ! -e "$backup_xml" ]]; then
    cp -p "$root_xml" "$backup_xml"
    echo "Preserved original XML: $backup_xml"
else
    echo "Keeping existing XML backup: $backup_xml"
fi

# Promote the requested MissAlignment snapshot to the active Warp metadata.
cp -f "$iteration_xml" "$root_xml"
echo "Activated iter$iteration XML: $iteration_xml -> $root_xml"

warp_python=${WARP_PYTHON:-/opt/miss-alignment/bin/python}
"$warp_python" \
    "$launcher_directory/rewrite_warp_xml_paths.py" \
    "$project_directory" \
    "$project_name" \
    "$project_directory"

shopt -s nullglob
raw_tilts=("$project_directory/${series_name}_Imod/split_tilts"/*.mrc)
if (( ${#raw_tilts[@]} == 0 )); then
    echo "No raw tilt MRC files found under ${series_name}_Imod/split_tilts." >&2
    exit 2
fi

export TMPDIR="$job_scratch/warp-reconstruction-tmp"
export PATH="/opt/warp/bin:$PATH"
export LD_LIBRARY_PATH="/opt/warp/lib:${LD_LIBRARY_PATH:-}"
export DOTNET_ROOT=/opt/warp/share/dotnet
export LC_ALL=C

loopback_hosts="localhost,127.0.0.1,::1"
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}$loopback_hosts"
export no_proxy="${no_proxy:+$no_proxy,}$loopback_hosts"

worker_launch_directory="$job_scratch/warp-reconstruction-worker"
mkdir -p "$TMPDIR" "$worker_launch_directory"

save_worker_diagnostics() {
    local diagnostics_directory="$processing_directory/warp_worker_diagnostics"
    local diagnostic_files=("$worker_launch_directory"/worker*.out "$worker_launch_directory"/worker*.err)
    if (( ${#diagnostic_files[@]} > 0 )); then
        mkdir -p "$diagnostics_directory"
        cp -f -- "${diagnostic_files[@]}" "$diagnostics_directory/" || true
    fi
}

echo "Input archive: $input_archive"
echo "Local project: $project_directory"
echo "Series: $series_name"
echo "MissAlignment iteration: iter$iteration"
echo "Raw tilt images: ${#raw_tilts[@]}"
echo "Reconstruction pixel size: $reconstruction_angpix A"
echo "Output archive: $output_archive"
echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<not set>}"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
else
    echo "nvidia-smi is not available inside this container; continuing without it."
fi

cd "$worker_launch_directory"
WarpTools change_selection --settings "$settings_file" --select

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
WarpTools ts_reconstruct \
    --settings "$settings_file" \
    --angpix "$reconstruction_angpix" &
child_pid=$!
wait "$child_pid"
reconstruction_status=$?
set -e
trap - TERM INT

if (( termination_requested != 0 && reconstruction_status == 0 )); then
    reconstruction_status=143
fi

save_worker_diagnostics

if (( reconstruction_status == 0 )); then
    echo "Generated miss-aligned reconstructions:"
    find "$processing_directory/reconstruction" -maxdepth 1 -type f -print
else
    echo "Warp reconstruction exited with status $reconstruction_status; packaging diagnostics and current project state." >&2
fi

tar -czf "$local_output" -C "$extract_root" "$project_name"
partial_output="${output_archive}.partial.$$"
cp "$local_output" "$partial_output"
mv -f "$partial_output" "$output_archive"
echo "Saved result archive: $output_archive"

exit "$reconstruction_status"
