#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 7 ]]; then
    echo "Usage: $0 DATA_DIRECTORY SERIES PIXEL_SIZE KV CS AMP_CONTRAST TILE_SIZE" >&2
    exit 2
fi

data_directory=$1
series=$2
pixel_size=$3
voltage=$4
cs=$5
amplitude_contrast=$6
tile_size=$7

if [[ ! -d "$data_directory" ]]; then
    echo "Data directory does not exist: $data_directory" >&2
    exit 1
fi

# Support either a flat directory (TS_3.mrc) or one directory per series
# (TS_3/TS_3.mrc).
input_mrc="$data_directory/$series.mrc"
series_directory="$data_directory/$series"
if [[ ! -f "$input_mrc" ]]; then
    input_mrc="$series_directory/$series.mrc"
fi
if [[ ! -f "$input_mrc" ]]; then
    echo "Cannot find either of these input stacks:" >&2
    echo "  $data_directory/$series.mrc" >&2
    echo "  $series_directory/$series.mrc" >&2
    exit 1
fi

output_directory="$data_directory/gctffind/$series"
output_spectrum="$output_directory/${series}_spectrum.mrc"
output_ctf="$output_directory/${series}_ctf.txt"
mkdir -p "$output_directory"

# Tilt angles are optional in GCtfFind. Use the first conventional angle file
# found beside the stack; otherwise GCtfFind still estimates CTF but omits the
# tilt-angle column from its text output.
angle_file=""
for candidate in \
    "$data_directory/$series.tlt" \
    "$data_directory/$series.rawtlt" \
    "$series_directory/$series.tlt" \
    "$series_directory/$series.rawtlt"; do
    if [[ -f "$candidate" ]]; then
        angle_file=$candidate
        break
    fi
done

echo "Series: $series"
echo "Input stack: $input_mrc"
echo "Output spectrum: $output_spectrum"
echo "Output CTF table: $output_ctf"
echo "Pixel size: $pixel_size A"
echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<not set>}"
if [[ -n "$angle_file" ]]; then
    echo "Tilt-angle file: $angle_file"
else
    echo "No .tlt or .rawtlt file found; continuing without -AngFile."
fi

command=(
    GCtfFind
    -InMrc "$input_mrc"
    -OutMrc "$output_spectrum"
    -OutCtf "$output_ctf"
    -PixSize "$pixel_size"
    -kV "$voltage"
    -Cs "$cs"
    -AmpContrast "$amplitude_contrast"
    -TileSize "$tile_size"
    -Gpu 0
)
if [[ -n "$angle_file" ]]; then
    command+=( -AngFile "$angle_file" )
fi

"${command[@]}"

test -s "$output_spectrum"
test -s "$output_ctf"
echo "GCtfFind completed successfully for $series."
