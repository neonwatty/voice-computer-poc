#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  swiftlint)
    version=0.65.1
    archive_name=portable_swiftlint.zip
    checksum=c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0
    url="https://github.com/realm/SwiftLint/releases/download/${version}/${archive_name}"
    ;;
  periphery)
    version=3.8.0
    archive_name=periphery-3.8.0.zip
    checksum=07d4e286e31dd79164df39097e0b59f533c94badbe18158464a455ea88a166d7
    url="https://github.com/peripheryapp/periphery/releases/download/${version}/${archive_name}"
    ;;
  *)
    echo "Usage: $0 swiftlint|periphery" >&2
    exit 2
    ;;
esac

tool="$1"
destination="${QUALITY_TOOLS_INSTALL_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/voice-computer-quality-tools}"
directory="${destination}/${tool}-${version}"
binary="${directory}/${tool}"

if [[ ! -x "$binary" ]]; then
  mkdir -p "$directory"
  archive="${directory}/${archive_name}"
  curl --fail --location --silent --show-error "$url" --output "$archive"
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  if [[ "$actual" != "$checksum" ]]; then
    echo "${tool} archive checksum mismatch" >&2
    exit 1
  fi
  unzip -q -o "$archive" -d "$directory"
fi

"$binary" version >&2
printf '%s\n' "$binary"
