#!/bin/sh
# Smoke-test a real Grimmory server against the endpoints kogrim relies on.
#
# Run this BEFORE debugging anything in KOReader: it confirms the endpoint
# paths and JSON field names this plugin assumes actually match your server's
# version. A mismatch here looks like an empty list or a silent failure on
# device, which is far harder to diagnose there.
#
# Usage:  ./tests/smoke.sh https://grimmory.example.com yourusername
#
# The password is read from the terminal, not taken as an argument, so it never
# lands in your shell history or the process list.

URL="${1%/}"
USER="$2"

if [ -z "$URL" ] || [ -z "$USER" ]; then
    echo "usage: $0 <server-url> <username>" >&2
    exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "this script needs jq (brew install jq)" >&2; exit 2; }

printf 'Password for %s: ' "$USER" >&2
stty -echo 2>/dev/null || true
read -r PASS
stty echo 2>/dev/null || true
echo >&2

BODY=$(mktemp)
STATUS=""
trap 'rm -f "$BODY"' EXIT

# get <path> -- fetch into $BODY, set $STATUS. Never exits on failure.
get() {
    STATUS=$(curl -s -o "$BODY" -w '%{http_code}' \
        -H "Authorization: Bearer $TOKEN" "$URL$1")
}

# show <path> <jq-filter> [label]
# Runs the filter, but falls back to the raw body when the response isn't the
# shape we expected -- a jq type error would otherwise abort the whole run and
# hide the actual server response, which is the one thing worth seeing.
show() {
    get "$1"
    if [ "$STATUS" != "200" ]; then
        echo "  UNEXPECTED STATUS $STATUS -- raw response:"
        head -c 800 "$BODY" | sed 's/^/    /'
        echo
        return 1
    fi
    if ! jq -e "$2" "$BODY" 2>/dev/null; then
        echo "  status 200 but the shape is not what kogrim expects -- raw response:"
        head -c 800 "$BODY" | sed 's/^/    /'
        echo
        return 1
    fi
}

echo "== 1. login =="
LOGIN=$(curl -s -X POST "$URL/api/v1/auth/login" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg u "$USER" --arg p "$PASS" '{username:$u,password:$p}')")
TOKEN=$(echo "$LOGIN" | jq -r '.accessToken // empty' 2>/dev/null)
if [ -z "$TOKEN" ]; then
    echo "FAILED. Server said:"; echo "$LOGIN" | jq . 2>/dev/null || echo "$LOGIN"
    exit 1
fi
echo "ok - got an access token"
echo "    refreshToken present: $(echo "$LOGIN" | jq 'has("refreshToken")')"

echo
echo "== 2. permissions (/app/users/me) =="
show /api/v1/app/users/me '.'

echo
echo "== 3. libraries =="
show /api/v1/app/libraries 'if type=="array" then [.[] | {id, name, bookCount}] else . end'

echo
echo "== 4. shelves =="
show /api/v1/app/shelves 'if type=="array" then [.[] | {id, name, bookCount}] else . end'

echo
echo "== 5. book list (page shape + first book) =="
if show "/api/v1/app/books?page=0&size=5&sort=title&dir=asc" \
        '{page, size, totalElements, totalPages, hasNext, hasPrevious}'; then
    cp "$BODY" /tmp/kogrim-books.json
    echo "first book:"
    jq '.content[0] | {id, title, authors, seriesName, seriesNumber,
                       readStatus, readProgress, primaryFileType,
                       primaryFileName, fileSizeKb}' /tmp/kogrim-books.json 2>/dev/null \
        || echo "  (could not read .content[0])"
fi

echo
echo "== 6. search =="
show "/api/v1/app/books/search?q=a&page=0&size=3" \
     '{totalElements, titles: [.content[]?.title]}'

echo
echo "== 7. continue-reading / recently-added =="
get '/api/v1/app/books/continue-reading?limit=3'
echo "  continue-reading: status $STATUS, type $(jq -r 'type' "$BODY" 2>/dev/null || echo '?')"
get '/api/v1/app/books/recently-added?limit=3'
echo "  recently-added:   status $STATUS, type $(jq -r 'type' "$BODY" 2>/dev/null || echo '?')"

ID=$(jq -r '.content[0].id // empty' /tmp/kogrim-books.json 2>/dev/null)

if [ -n "$ID" ]; then
    echo
    echo "== 8. book detail (id $ID) =="
    show "/api/v1/app/books/$ID" \
        '{id, title, description: (.description // "" | .[0:60]), pageCount,
          primaryFileType, fileTypes}'

    echo
    echo "== 9. download (headers only, nothing written) =="
    curl -s -o /dev/null -D - -H "Authorization: Bearer $TOKEN" \
        "$URL/api/v1/books/$ID/download" \
        | grep -iE '^(HTTP/|content-type|content-length|content-disposition)' || true
else
    echo
    echo "== 8/9 skipped: no book id available from step 5 =="
fi

echo
echo "== 10. 401 handling (deliberately bad token) =="
echo "expect 401: $(curl -s -o /dev/null -w '%{http_code}' \
    -H 'Authorization: Bearer not-a-real-token' "$URL/api/v1/app/libraries")"

echo
echo "done."
