#!/bin/sh
# Install (or reinstall) kogrim onto a USB-connected Kobo running KOReader.
#
# Usage:  ./tools/install-kobo.sh          # install
#         ./tools/install-kobo.sh --log    # fetch crash.log off the device
#         ./tools/install-kobo.sh --remove # uninstall
#
# The device must be plugged in and mounted. Nothing here touches your books,
# your KOReader settings, or any other plugin -- it only writes the
# plugins/kogrim.koplugin directory.

set -e

VOLUME="${KOBO_VOLUME:-/Volumes/KOBOeReader}"
KOREADER="$VOLUME/.adds/koreader"
PLUGINS="$KOREADER/plugins"
TARGET="$PLUGINS/kogrim.koplugin"

SRC="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -d "$VOLUME" ]; then
    echo "No Kobo found at $VOLUME." >&2
    echo >&2
    echo "Plug the device in and tap 'Connect' on its screen. If your volume is" >&2
    echo "named differently, check 'ls /Volumes' and re-run with:" >&2
    echo "  KOBO_VOLUME=/Volumes/YourName $0" >&2
    exit 1
fi

if [ ! -d "$KOREADER" ]; then
    echo "Found $VOLUME, but no KOReader at $KOREADER." >&2
    echo "Is KOReader actually installed on this device?" >&2
    exit 1
fi

case "$1" in
--log)
    if [ -f "$KOREADER/crash.log" ]; then
        # The log is appended to across runs, so the newest traceback is at the
        # end -- that's the one that matters after a crash you just triggered.
        echo "== last 80 lines of $KOREADER/crash.log =="
        tail -80 "$KOREADER/crash.log"
    else
        echo "No crash.log on the device -- nothing has crashed yet."
    fi
    exit 0
    ;;
--remove)
    rm -rf "$TARGET"
    echo "Removed $TARGET"
    echo "Restart KOReader for it to take effect."
    exit 0
    ;;
esac

# Refuse to install something that doesn't compile. Catching a syntax error
# here costs seconds; catching it on the device costs an unplug/replug cycle
# and a KOReader that won't start.
if command -v luajit >/dev/null 2>&1; then
    echo "Checking syntax..."
    for f in $(find "$SRC" -name '*.lua' -not -path '*/tests/*'); do
        luajit -b "$f" /dev/null || {
            echo "Syntax error in $f -- not installing." >&2
            exit 1
        }
    done
    echo "  ok"
fi

mkdir -p "$PLUGINS"
rm -rf "$TARGET"
mkdir -p "$TARGET"

# Copy only what the plugin needs at runtime. tests/, tools/ and .github/ are
# development-only and would just take up space on the device.
for item in _meta.lua main.lua lib locale README.md; do
    [ -e "$SRC/$item" ] && cp -R "$SRC/$item" "$TARGET/"
done

# macOS sprinkles ._* AppleDouble files onto FAT volumes. KOReader's plugin
# loader ignores them, but they clutter the directory and confuse a later diff.
find "$TARGET" -name '._*' -delete 2>/dev/null || true
find "$TARGET" -name '.DS_Store' -delete 2>/dev/null || true

echo
echo "Installed to $TARGET"
echo "  $(find "$TARGET" -name '*.lua' | wc -l | tr -d ' ') Lua files, $(du -sh "$TARGET" | cut -f1)"
echo
echo "Next:"
echo "  1. Eject the Kobo (drag to Trash, or: diskutil eject $VOLUME)"
echo "  2. Unplug it and let it finish 'Processing content'"
echo "  3. Open KOReader"
echo "  4. Tools > Grimmory > Server and account"
echo
echo "If something goes wrong, plug back in and run: $0 --log"
