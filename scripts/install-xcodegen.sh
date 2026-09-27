#!/usr/bin/env bash
set -euo pipefail

version=2.46.0
checksum=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
destination="${XCODEGEN_INSTALL_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/voice-computer-xcodegen-${version}}"
binary="${destination}/xcodegen/bin/xcodegen"

if [[ ! -x "$binary" ]]; then
  mkdir -p "$destination"
  archive="${destination}/xcodegen.zip"
  curl --fail --location --silent --show-error \
    "https://github.com/yonaskolb/XcodeGen/releases/download/${version}/xcodegen.zip" \
    --output "$archive"
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  if [[ "$actual" != "$checksum" ]]; then
    echo "XcodeGen archive checksum mismatch" >&2
    exit 1
  fi
  unzip -q -o "$archive" -d "$destination"
fi

"$binary" --version
printf '%s\n' "$binary"
