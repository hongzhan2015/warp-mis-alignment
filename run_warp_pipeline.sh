#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 PROJECT_DIRECTORY" >&2
    exit 2
fi

project_directory=$1
if [[ ! -d "$project_directory" ]]; then
    echo "Project directory does not exist: $project_directory" >&2
    exit 2
fi

project_directory=$(cd "$project_directory" && pwd -P)
split_tilts_directory="$project_directory/TS_2_Imod/split_tilts"
mdoc_directory="$project_directory/TS_2_Imod/mdoc"
alignment_directory="$project_directory/warp_alignment"
frameseries_directory="$project_directory/warp_frameseries"
tomostar_directory="$project_directory/tomostar"
tiltseries_directory="$project_directory/warp_tiltseries"
frameseries_settings="$project_directory/warp_frameseries.settings"
tiltseries_settings="$project_directory/warp_tiltseries.settings"

shopt -s nullglob
mrc_files=("$split_tilts_directory"/*.mrc)
mdoc_files=("$mdoc_directory"/*.mdoc)
alignment_xf=("$alignment_directory"/TS_2/*.xf)
alignment_tlt=("$alignment_directory"/TS_2/*.tlt)

if (( ${#mrc_files[@]} == 0 )); then
    echo "No MRC files found in TS_2_Imod/split_tilts" >&2
    exit 2
fi
if (( ${#mdoc_files[@]} == 0 )); then
    echo "No MDOC files found in TS_2_Imod/mdoc" >&2
    exit 2
fi
if (( ${#alignment_xf[@]} == 0 || ${#alignment_tlt[@]} == 0 )); then
    echo "Expected both XF and TLT alignment files in warp_alignment/TS_2" >&2
    exit 2
fi

mkdir -p \
    "$frameseries_directory" \
    "$tomostar_directory" \
    "$tiltseries_directory"

job_scratch=${_CONDOR_SCRATCH_DIR:-/tmp}
export TMPDIR="$job_scratch/warp-tmp"
export PATH="/opt/warp/bin:$PATH"
export LD_LIBRARY_PATH="/opt/warp/lib:${LD_LIBRARY_PATH:-}"
export DOTNET_ROOT=/opt/warp/share/dotnet
worker_launch_directory="$job_scratch/warp-worker-launch"
mkdir -p "$TMPDIR" "$worker_launch_directory"

save_worker_diagnostics() {
    local diagnostics_directory="$project_directory/warp_worker_diagnostics"
    local diagnostic_files=("$worker_launch_directory"/worker*.out "$worker_launch_directory"/worker*.err)
    if (( ${#diagnostic_files[@]} > 0 )); then
        mkdir -p "$diagnostics_directory"
        cp -f -- "${diagnostic_files[@]}" "$diagnostics_directory/" || true
    fi
}
trap save_worker_diagnostics EXIT

# Warp dev39 workers recursively watch their current directory before they
# report their localhost port. Launching from a project tree on networked
# /staging can exceed the 20-second connection timeout. Keep the working
# directory small and local, and give WarpTools absolute data/output paths.
cd "$worker_launch_directory"

echo "Project: $project_directory"
echo "MRC files: ${#mrc_files[@]}"
echo "MDOC files: ${#mdoc_files[@]}"
echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<not set>}"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
else
    echo "nvidia-smi is not available inside this container; continuing without it."
fi

echo "[1/7] Creating frame-series settings"
WarpTools create_settings \
    --folder_data "$split_tilts_directory" \
    --folder_processing "$frameseries_directory" \
    --output "$frameseries_settings" \
    --extension "*.mrc" \
    --angpix 3.427 \
    --exposure 2.67

echo "[2/7] Estimating frame-series CTF"
WarpTools fs_ctf \
    --settings "$frameseries_settings" \
    --grid 1x1x1 \
    --range_min 40 \
    --range_max 8 \
    --defocus_min 0.5 \
    --defocus_max 8 \
    --voltage 300 \
    --cs 2.7 \
    --amplitude 0.07 \
    --use_sum

echo "[3/7] Exporting aligned averages"
WarpTools fs_export_micrographs \
    --settings "$frameseries_settings" \
    --averages

echo "[4/7] Creating TomoSTAR files"
WarpTools ts_import \
    --mdocs "$mdoc_directory" \
    --frameseries "$frameseries_directory" \
    --tilt_exposure 2.67 \
    --output "$tomostar_directory"

echo "[5/7] Creating tilt-series settings"
WarpTools create_settings \
    --output "$tiltseries_settings" \
    --folder_processing "$tiltseries_directory" \
    --folder_data "$tomostar_directory" \
    --extension "*.tomostar" \
    --angpix 3.427 \
    --tomo_dimensions 2046x2880x2000

echo "[6/7] Importing IMOD alignments"
WarpTools ts_import_alignments \
    --settings "$tiltseries_settings" \
    --alignments "$alignment_directory" \
    --alignment_angpix 3.427

echo "[7/7] Reconstructing tomogram"
WarpTools ts_reconstruct \
    --settings "$tiltseries_settings" \
    --angpix 13.71

echo "Generated Warp XML files:"
find "$tiltseries_directory" -maxdepth 1 -type f -name '*.xml' -print
echo "Generated reconstructions:"
find "$tiltseries_directory/reconstruction" -maxdepth 1 -type f -print
echo "WarpTools pipeline completed successfully."
