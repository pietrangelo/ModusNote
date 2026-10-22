#!/usr/bin/env bash
# The Worker end to end: builds it, serves it with `wrangler dev` (workerd,
# Durable Objects and R2 on this machine, nothing on Cloudflare) and runs
# e2e.py against it. Wrangler comes from tool/deploy's lockfile.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
port=${MODUSNOTE_E2E_PORT:-8787}
state=$(mktemp -d)
log="$state/wrangler.log"

(cd "$root/tool/deploy" && npm ci --no-audit --no-fund --silent)
python3 -c 'import cryptography' 2>/dev/null || sudo apt-get install -y -qq python3-cryptography

# Static assets are served beside the API; the tests need only some.
assets="$root/apps/modusnote/build/web"
if [ ! -f "$assets/index.html" ]; then
  mkdir -p "$assets"
  echo '<!doctype html><title>e2e</title>' > "$assets/index.html"
fi

cd "$root/server/worker"
WRANGLER_SEND_METRICS=false "$root/tool/deploy/node_modules/.bin/wrangler" dev \
  --var OBJECT_PLACEMENT:local --ip 127.0.0.1 --port "$port" \
  --persist-to "$state/data" --show-interactive-dev-session=false > "$log" 2>&1 &
wrangler=$!
trap 'kill $wrangler 2>/dev/null || true; rm -rf "$state"' EXIT

for _ in $(seq 1 300); do
  grep -q 'Ready on' "$log" && break
  kill -0 $wrangler 2>/dev/null || { cat "$log"; exit 1; }
  sleep 1
done
grep -q 'Ready on' "$log" || { cat "$log"; exit 1; }

NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 python3 -I "$root/server/e2e/e2e.py" "http://127.0.0.1:$port"
