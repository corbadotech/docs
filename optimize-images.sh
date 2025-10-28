#!/bin/bash
set -euo pipefail

MAX_DIM=16383
QUALITY="${QUALITY:-90}"   # allow override: QUALITY=85 ./convert.sh

have_identify=false
have_sips=false
command -v identify >/dev/null 2>&1 && have_identify=true
command -v sips >/dev/null 2>&1 && have_sips=true

if ! $have_identify && ! $have_sips; then
  echo "Error: need 'identify' (ImageMagick) or 'sips' (macOS) to read image sizes." >&2
  exit 1
fi

# get WxH or empty on failure
get_dims() {
  local f="$1"
  if $have_identify; then
    identify -format "%w %h" "$f" 2>/dev/null || true
  else
    # sips prints like: pixelHeight: 1234\npixelWidth: 5678
    local w h
    w=$(sips -g pixelWidth "$f" 2>/dev/null | awk '/pixelWidth/ {print $2}')
    h=$(sips -g pixelHeight "$f" 2>/dev/null | awk '/pixelHeight/ {print $2}')
    if [[ -n "$w" && -n "$h" ]]; then echo "$w $h"; fi
  fi
}

convert_one() {
  local input_file="$1"
  local lc="$(echo "$input_file" | tr '[:upper:]' '[:lower:]')"
  case "$lc" in
    *.jpg|*.jpeg|*.png) ;;
    *) return 0 ;;
  esac

  local output_file="${input_file%.*}.webp"
  if [[ "$input_file" == "$output_file" ]]; then return 0; fi

  # get dimensions
  read -r W H <<<"$(get_dims "$input_file")"
  if [[ -z "${W:-}" || -z "${H:-}" || "$W" -eq 0 || "$H" -eq 0 ]]; then
    echo "⚠️  Skipping (unknown or invalid dimensions): $input_file"
    return 0
  fi

  # decide resize
  local resize_opt=()
  if (( W > MAX_DIM || H > MAX_DIM )); then
    # scale so that the longest side == MAX_DIM, keep aspect ratio
    if (( W >= H )); then
      resize_opt=(-resize "$MAX_DIM" 0)   # width capped, height auto
    else
      resize_opt=(-resize 0 "$MAX_DIM")   # height capped, width auto
    fi
    echo "Resizing large image ($W x $H) → within ${MAX_DIM}px: $input_file"
  fi

  echo "Converting $input_file → $output_file"
  # -mt enables multithreading; -q sets quality; -metadata icc/xmp to keep color profile if present
  if cwebp -q "$QUALITY" -mt "${resize_opt[@]}" -metadata icc -metadata xmp "$input_file" -o "$output_file" >/dev/null 2>&1; then
    echo "✅  $output_file"
  else
    echo "❌  Conversion failed: $input_file"
  fi
}

export -f convert_one get_dims
export MAX_DIM QUALITY have_identify have_sips

# Robust recursion (handles spaces/newlines)
find . -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -print0 \
  | xargs -0 -I{} bash -c 'convert_one "$@"' _ {}
echo "Done."
