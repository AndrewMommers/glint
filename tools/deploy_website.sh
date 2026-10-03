#!/usr/bin/env bash
# Deploys website/ to Appwrite Sites as a static site and makes it live.
# Used by .github/workflows/deploy-website.yml on every push that touches
# website/, and can be run by hand from Git Bash.
#
# Needs an Appwrite API key with the sites.read and sites.write scopes, from
# $APPWRITE_SITES_KEY or beta/server-data/appwrite-sites.key (git-ignored).
# Endpoint and project come from beta/appwrite.json unless set in the env.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cfg="$root/beta/appwrite.json"
json_field() { sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p" "$cfg" | head -1; }

ENDPOINT="${APPWRITE_ENDPOINT:-$(json_field endpoint)}"
PROJECT="${APPWRITE_PROJECT:-$(json_field project)}"
SITE_ID="${APPWRITE_SITE_ID:-glint}"
KEY="${APPWRITE_SITES_KEY:-}"
if [ -z "$KEY" ] && [ -f "$root/beta/server-data/appwrite-sites.key" ]; then
  KEY="$(tr -d '\r\n' < "$root/beta/server-data/appwrite-sites.key")"
fi
[ -n "$KEY" ] || { echo "no Appwrite key: set APPWRITE_SITES_KEY or create beta/server-data/appwrite-sites.key" >&2; exit 1; }

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
field() { sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p" | head -1; }

# 1. Make sure the site exists (static, no build step, served from the upload root).
if ! api GET "/sites/$SITE_ID" >/dev/null 2>&1; then
  echo "creating site '$SITE_ID'"
  api POST /sites -H 'Content-Type: application/json' -d "{
    \"siteId\": \"$SITE_ID\", \"name\": \"Glint website\",
    \"framework\": \"other\", \"buildRuntime\": \"node-22\", \"adapter\": \"static\",
    \"installCommand\": \"\", \"buildCommand\": \"\", \"outputDirectory\": \"./\",
    \"fallbackFile\": \"index.html\" }" >/dev/null
fi

# 2. Package website/ and upload it as a new deployment, activated once built.
pkg="$(mktemp -d)/site.tar.gz"
tar -czf "$pkg" -C "$root/website" .
echo "uploading $(du -h "$pkg" | cut -f1) package"
dep="$(api POST "/sites/$SITE_ID/deployments" -F "code=@$pkg;type=application/gzip" -F activate=true)"
dep_id="$(printf '%s' "$dep" | field '\$id')"
echo "deployment $dep_id"

# 3. Wait for the build to finish.
for _ in $(seq 1 60); do
  status="$(api GET "/sites/$SITE_ID/deployments/$dep_id" | field status)"
  case "$status" in
    ready) break ;;
    failed|canceled) echo "deployment $status" >&2; exit 1 ;;
  esac
  sleep 5
done
[ "$status" = ready ] || { echo "timed out (status: $status)" >&2; exit 1; }

# 4. Report the live address.
url="$(api GET "/proxy/rules?queries%5B0%5D=%7B%22method%22%3A%22equal%22%2C%22attribute%22%3A%22deploymentResourceId%22%2C%22values%22%3A%5B%22$SITE_ID%22%5D%7D" 2>/dev/null | field domain || true)"
echo "live: ${url:+https://$url}"
