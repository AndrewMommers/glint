#!/usr/bin/env bash
# Uploads a release to the public Appwrite Storage bucket the website links to,
# then writes website/release.json so the site shows the new version.
#
#   bash tools/publish_download.sh <version> <Glint-Setup-x.exe> [<Glint-x-windows.zip>]
#
# Files keep stable ids (setup-latest, zip-latest), so the download links never
# change; each upload replaces the previous build. Needs an Appwrite API key with
# buckets.read, buckets.write, files.read and files.write, from
# $APPWRITE_RELEASE_KEY or beta/server-data/appwrite-release.key (git-ignored).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cfg="$root/beta/appwrite.json"
json_field() { sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p" "$cfg" | head -1; }

VERSION="$1"; SETUP="$2"; ZIP="${3:-}"
ENDPOINT="${APPWRITE_ENDPOINT:-$(json_field endpoint)}"
PROJECT="${APPWRITE_PROJECT:-$(json_field project)}"
BUCKET="downloads"
KEY="${APPWRITE_RELEASE_KEY:-}"
if [ -z "$KEY" ] && [ -f "$root/beta/server-data/appwrite-release.key" ]; then
  KEY="$(tr -d '\r\n' < "$root/beta/server-data/appwrite-release.key")"
fi
[ -n "$KEY" ] || { echo "no Appwrite key: set APPWRITE_RELEASE_KEY or create beta/server-data/appwrite-release.key" >&2; exit 1; }

api() { # api METHOD PATH [curl args...] -> body on stdout, fails on HTTP >= 400
  local method="$1" path="$2"; shift 2
  local out code
  out="$(curl -sS -X "$method" "$ENDPOINT$path" \
    -H "X-Appwrite-Project: $PROJECT" -H "X-Appwrite-Key: $KEY" \
    -H "X-Appwrite-Response-Format: 2.3.0" -w '\n%{http_code}' "$@")"
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  if [ "$code" -ge 400 ]; then echo "$method $path -> HTTP $code: $out" >&2; return 1; fi
  printf '%s' "$out"
}

# 1. Public, read-only bucket (created once). 50 MB is the free plan's per-file cap.
if ! api GET "/storage/buckets/$BUCKET" >/dev/null 2>&1; then
  echo "creating bucket '$BUCKET'"
  api POST /storage/buckets -H 'Content-Type: application/json' -d "{
    \"bucketId\": \"$BUCKET\", \"name\": \"Game downloads\",
    \"permissions\": [\"read(\\\"any\\\")\"], \"fileSecurity\": false,
    \"maximumFileSize\": 50000000, \"allowedFileExtensions\": [\"exe\", \"zip\"],
    \"compression\": \"none\", \"encryption\": false, \"antivirus\": true }" >/dev/null
fi

# 2. Replace a file under a stable id. Appwrite takes uploads in 5 MB chunks.
upload() { # upload <fileId> <path>
  local id="$1" path="$2" name size chunk=$((5 * 1024 * 1024)) off=0 part tmp
  name="$(basename "$path")"; size="$(wc -c < "$path" | tr -d ' ')"
  api DELETE "/storage/buckets/$BUCKET/files/$id" >/dev/null 2>&1 || true
  tmp="$(mktemp -d)"
  # Native Windows curl (Git Bash) can't read MSYS paths like /tmp/..., so hand it a Windows path.
  command -v cygpath >/dev/null && tmp="$(cygpath -m "$tmp")"
  echo "uploading $name ($((size / 1048576)) MB) as $id"
  while [ "$off" -lt "$size" ]; do
    part="$tmp/$name"
    dd if="$path" of="$part" bs="$chunk" skip="$((off / chunk))" count=1 status=none
    local end=$((off + $(wc -c < "$part" | tr -d ' ') - 1))
    local extra=(); [ "$off" -gt 0 ] && extra=(-H "X-Appwrite-ID: $id")
    api POST "/storage/buckets/$BUCKET/files" "${extra[@]}" \
      -H "Content-Range: bytes $off-$end/$size" \
      -F "fileId=$id" -F "file=@$part;filename=$name" >/dev/null
    off=$((end + 1))
    printf '  %3d%%\r' $((off * 100 / size))
  done
  echo
  rm -rf "$tmp"
}

link() { echo "$ENDPOINT/storage/buckets/$BUCKET/files/$1/download?project=$PROJECT"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
bytes() { wc -c < "$1" | tr -d ' '; }

upload setup-latest "$SETUP"
zip_json=""
if [ -n "$ZIP" ]; then
  upload zip-latest "$ZIP"
  zip_json=",
  \"zip\": { \"name\": \"$(basename "$ZIP")\", \"url\": \"$(link zip-latest)\", \"bytes\": $(bytes "$ZIP"), \"sha256\": \"$(sha "$ZIP")\" }"
fi

# 3. Tell the website about it (deployed by the website workflow once pushed).
cat > "$root/website/release.json" <<EOF
{
  "version": "$VERSION",
  "date": "$(date -u +%Y-%m-%d)",
  "setup": { "name": "$(basename "$SETUP")", "url": "$(link setup-latest)", "bytes": $(bytes "$SETUP"), "sha256": "$(sha "$SETUP")" }$zip_json
}
EOF
echo "wrote website/release.json for $VERSION"
