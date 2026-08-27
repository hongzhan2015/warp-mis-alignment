#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 PROJECT_DIRECTORY [RECONSTRUCTION_ANGPIX]" >&2
    echo "Example: $0 /data/output_TS_3_run001 12" >&2
    exit 2
fi

project_directory=$(cd "$1" && pwd -P)
reconstruction_angpix=${2:-12}
project_name=$(basename "$project_directory")

if [[ ! "$project_name" =~ ^output_(TS_[0-9]+)_run[0-9]+$ ]]; then
    echo "Expected a project named output_TS_N_runNNN, got: $project_name" >&2
    exit 2
fi
ts_name=${BASH_REMATCH[1]}

if [[ ! "$reconstruction_angpix" =~ ^[0-9]+([.][0-9]+)?$ ]] || \
   ! awk -v value="$reconstruction_angpix" 'BEGIN { exit !(value > 0) }'; then
    echo "RECONSTRUCTION_ANGPIX must be a positive number." >&2
    exit 2
fi

script_directory=$(cd "$(dirname "$0")" && pwd -P)
relocator="$script_directory/rewrite_warp_xml_paths.py"
settings="$project_directory/warp_tiltseries.settings"
raw_tilt_directory="$project_directory/${ts_name}_Imod/split_tilts"

if [[ ! -r "$relocator" ]]; then
    echo "Missing relocation helper: $relocator" >&2
    exit 2
fi
if [[ ! -r "$settings" ]]; then
    echo "Missing Warp settings: $settings" >&2
    exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is not available." >&2
    exit 2
fi
if ! command -v WarpTools >/dev/null 2>&1; then
    echo "WarpTools is not available; activate the Warp conda environment." >&2
    exit 2
fi

shopt -s nullglob
raw_tilts=("$raw_tilt_directory"/*.mrc)
if (( ${#raw_tilts[@]} == 0 )); then
    echo "No raw tilt MRC files found in: $raw_tilt_directory" >&2
    echo "Restore ${ts_name}_Imod/split_tilts from the full Warp archive." >&2
    exit 2
fi

echo "Project: $project_directory"
echo "Tilt series: $ts_name"
echo "Raw tilt images: ${#raw_tilts[@]}"
echo "Reconstruction pixel size: $reconstruction_angpix A"

# Relocate absolute project paths in all Warp metadata. This helper uses only
# the Python standard library and does not require PyYAML.
python3 "$relocator" "$project_directory" "$project_name" "$project_directory"

# Repair metadata affected by an older manual replacement in which the source
# ended with '/' but the replacement did not, producing ...run001TS_N_Imod.
bad_join="${project_directory}${ts_name}_Imod"
good_join="${project_directory}/${ts_name}_Imod"
while IFS= read -r -d '' metadata_file; do
    sed -i "s|$bad_join|$good_join|g" "$metadata_file"
done < <(
    grep -rlZF "$bad_join" "$project_directory" \
        --include='*.xml' --include='*.settings' --include='*.tomostar' || true
)

remaining_staging=$(grep -rl '/staging/' "$project_directory" \
    --include='*.xml' --include='*.settings' --include='*.tomostar' || true)
if [[ -n "$remaining_staging" ]]; then
    echo "Some Warp metadata still contains staging paths:" >&2
    echo "$remaining_staging" >&2
    exit 2
fi

WarpTools change_selection --settings "$settings" --select
WarpTools ts_reconstruct --settings "$settings" --angpix "$reconstruction_angpix"

echo "Local Warp reconstruction completed for $ts_name."
