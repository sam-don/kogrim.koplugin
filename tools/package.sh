#!/bin/sh
# Build a release zip.
#
# The archive MUST contain a single top-level directory named
# `kogrim.koplugin`, because that is the directory KOReader expects under
# plugins/ and it derives the plugin's identity from that name. This repository
# *is* the plugin -- its root holds _meta.lua -- so the files get staged into a
# correctly-named directory first rather than zipped in place.
#
# Usage:  ./tools/package.sh [output-dir]
# Prints the path of the archive it wrote.

set -e

cd "$(dirname "$0")/.."
OUT_DIR="${1:-dist}"

VERSION=$(grep -oE 'version = "[^"]+"' _meta.lua | head -1 | cut -d'"' -f2)
if [ -z "$VERSION" ]; then
    echo "could not read version from _meta.lua" >&2
    exit 1
fi

STAGE="$OUT_DIR/kogrim.koplugin"
ZIP="$OUT_DIR/kogrim.koplugin-v$VERSION.zip"

rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE"

# Runtime files only. tests/, tools/ and .github/ are development-only and
# would just take up space on a device with limited storage.
for item in _meta.lua main.lua lib locale README.md LICENSE; do
    [ -e "$item" ] && cp -R "$item" "$STAGE/"
done

# macOS AppleDouble files and Finder droppings must never reach the archive.
find "$STAGE" -name '._*' -delete 2>/dev/null || true
find "$STAGE" -name '.DS_Store' -delete 2>/dev/null || true

( cd "$OUT_DIR" && zip -q -r "kogrim.koplugin-v$VERSION.zip" kogrim.koplugin )
rm -rf "$STAGE"

echo "$ZIP"
