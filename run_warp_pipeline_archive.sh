#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 PROJECT.tar.gz PROJECT_NAME SERIES_NAME" >&2
    exit 2
fi

project_archive=$1
project_name=$2
series_name=$3

if [[ ! -r "$project_archive" ]]; then
    echo "Cannot read project archive: $project_archive" >&2
    exit 2
fi
if [[ "$project_archive" != *.tar.gz ]]; then
    echo "Project archive name must end in .tar.gz" >&2
    exit 2
fi
if [[ ! "$project_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Unsafe project name: $project_name" >&2
    exit 2
fi
if [[ ! "$series_name" =~ ^TS_[0-9]+$ ]]; then
    echo "Invalid series name '$series_name'; expected TS_N." >&2
    exit 2
fi
archive_parent=$(dirname "$project_archive")
if [[ ! -w "$archive_parent" ]]; then
    echo "Archive directory is not writable: $archive_parent" >&2
    exit 2
fi

job_scratch=${_CONDOR_SCRATCH_DIR:-/tmp}
launcher_directory=$(cd "$(dirname "$0")" && pwd -P)
extract_root="$job_scratch/archive-work"
local_input="$job_scratch/input.tar.gz"
local_output="$job_scratch/output.tar.gz"
member_list="$job_scratch/archive-members.txt"
project_directory="$extract_root/$project_name"

mkdir -p "$extract_root"
cp "$project_archive" "$local_input"
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

echo "Archive: $project_archive"
echo "Local project: $project_directory"
echo "Series: $series_name"
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
bash "$launcher_directory/run_warp_pipeline.sh" \
    "$project_directory" \
    "$series_name" &
child_pid=$!
wait "$child_pid"
pipeline_status=$?
set -e
trap - TERM INT

if (( termination_requested != 0 && pipeline_status == 0 )); then
    pipeline_status=143
fi

echo "Packaging project after Warp pipeline exit status $pipeline_status"
tar -czf "$local_output" -C "$extract_root" "$project_name"

# Keep the original staging archive intact until a complete replacement has
# been copied. The final rename occurs within staging and is therefore atomic.
partial_archive="${project_archive}.partial.$$"
cp "$local_output" "$partial_archive"
mv -f "$partial_archive" "$project_archive"
echo "Updated archive: $project_archive"

exit "$pipeline_status"
