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

cd "$project_directory"

shopt -s nullglob
mrc_files=(TS_2_Imod/split_tilts/*.mrc)
mdoc_files=(TS_2_Imod/mdoc/*.mdoc)
alignment_xf=(warp_alignment/TS_2/*.xf)
alignment_tlt=(warp_alignment/TS_2/*.tlt)

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

mkdir -p warp_frameseries tomostar warp_tiltseries

job_scratch=${_CONDOR_SCRATCH_DIR:-/tmp}
export TMPDIR="$job_scratch/warp-tmp"
export PATH="/opt/warp/bin:$PATH"
export LD_LIBRARY_PATH="/opt/warp/lib:${LD_LIBRARY_PATH:-}"
export DOTNET_ROOT=/opt/warp/share/dotnet
mkdir -p "$TMPDIR"

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
    --folder_data TS_2_Imod/split_tilts \
    --folder_processing warp_frameseries \
    --output warp_frameseries.settings \
    --extension "*.mrc" \
    --angpix 3.427 \
    --exposure 2.67

echo "[2/7] Estimating frame-series CTF"
WarpTools fs_ctf \
    --settings warp_frameseries.settings \
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
    --settings warp_frameseries.settings \
    --averages

echo "[4/7] Creating TomoSTAR files"
WarpTools ts_import \
    --mdocs TS_2_Imod/mdoc \
    --frameseries warp_frameseries \
    --tilt_exposure 2.67 \
    --output tomostar

echo "[5/7] Creating tilt-series settings"
WarpTools create_settings \
    --output warp_tiltseries.settings \
    --folder_processing warp_tiltseries \
    --folder_data tomostar \
    --extension "*.tomostar" \
    --angpix 3.427 \
    --tomo_dimensions 2046x2880x2000

echo "[6/7] Importing IMOD alignments"
WarpTools ts_import_alignments \
    --settings warp_tiltseries.settings \
    --alignments warp_alignment \
    --alignment_angpix 3.427

echo "[7/7] Reconstructing tomogram"
WarpTools ts_reconstruct \
    --settings warp_tiltseries.settings \
    --angpix 13.71

echo "Generated Warp XML files:"
find warp_tiltseries -maxdepth 1 -type f -name '*.xml' -print
echo "Generated reconstructions:"
find warp_tiltseries/reconstruction -maxdepth 1 -type f -print
echo "WarpTools pipeline completed successfully."

