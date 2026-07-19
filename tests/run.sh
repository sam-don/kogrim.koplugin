#!/bin/sh
# Run the kogrim test suite. Needs luajit (the real KOReader runtime, so the
# 5.1 dialect is enforced exactly as on device) and, optionally, msgfmt.
set -e

cd "$(dirname "$0")/.."

status=0

echo "== syntax =="
for f in $(find . -name '*.lua' | sort); do
    if luajit -b "$f" /dev/null 2>/tmp/kogrim-syntax-err; then
        echo "ok   $f"
    else
        echo "FAIL $f"
        cat /tmp/kogrim-syntax-err
        status=1
    fi
done

echo ""
echo "== accidental globals =="
# Any GSET in the bytecode is a write to a global -- always a bug in a plugin,
# where the require namespace is shared with the whole of KOReader.
leaks=$(for f in $(find . -name '*.lua'); do
    luajit -bl "$f" 2>/dev/null | grep 'GSET' | sed "s|^|$f: |"
done)
if [ -n "$leaks" ]; then
    echo "FAIL global writes found:"
    echo "$leaks"
    status=1
else
    echo "ok   no global writes"
fi

echo ""
echo "== logic =="
luajit tests/_test_logic.lua || status=1

if command -v msgfmt >/dev/null 2>&1; then
    echo ""
    echo "== translations =="
    for po in locale/*.po locale/*.pot; do
        [ -e "$po" ] || continue
        if msgfmt --check-format -o /dev/null "$po" 2>/dev/null; then
            echo "ok   $po"
        else
            echo "FAIL $po"
            status=1
        fi
    done
fi

echo ""
if [ "$status" -eq 0 ]; then
    echo "PASS"
else
    echo "FAIL"
fi
exit $status
