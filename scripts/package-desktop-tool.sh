#!/bin/bash
set -euo pipefail

source_root="${SRCROOT:?}/DesktopToolServer"
scratch_root="${DERIVED_FILE_DIR:?}/DesktopToolServer-${CONFIGURATION:?}"
bundle_helpers="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}/Contents/Helpers"
case "$CONFIGURATION" in
  Debug) swift_configuration=debug ;;
  Release) swift_configuration=release ;;
  *) echo "Unsupported helper configuration" >&2; exit 1 ;;
esac

/usr/bin/swift build --package-path "$source_root" --scratch-path "$scratch_root" \
  --configuration "$swift_configuration" --product DesktopToolServer \
  --disable-automatic-resolution
product="$scratch_root/$swift_configuration/DesktopToolServer"
if [[ ! -f "$product" || -L "$product" || ! -x "$product" ]]; then
  echo "DesktopToolServer build product missing or invalid" >&2
  exit 1
fi

mkdir -p "$bundle_helpers"
destination="$bundle_helpers/DesktopToolServer"
manifest="$bundle_helpers/DesktopToolServer.sha256"
rm -f "$destination" "$manifest"
cp "$product" "$destination"
chmod 755 "$destination"
if [[ ! -f "$destination" || -L "$destination" || ! -x "$destination" ]]; then
  echo "Bundled DesktopToolServer is invalid" >&2
  exit 1
fi
product_hash="$(/usr/bin/shasum -a 256 "$product" | /usr/bin/awk '{print $1}')"
bundle_hash="$(/usr/bin/shasum -a 256 "$destination" | /usr/bin/awk '{print $1}')"
if [[ "$product_hash" != "$bundle_hash" ]]; then
  echo "Bundled DesktopToolServer differs from build product" >&2
  exit 1
fi
printf '%s\n' "$bundle_hash" > "$manifest"
