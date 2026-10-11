#!/usr/bin/env bash
# Runs the Dart SupabaseSyncServer against a real PostgREST (the server
# Supabase puts in front of PostgreSQL) on a throwaway cluster, so the
# adapter is checked against actual RLS, triggers and wire formats rather
# than only against its own idea of them.
#
# PostgREST is downloaded with a pinned hash; MODUSNOTE_POSTGREST=/path/to/postgrest
# uses a local binary instead (offline builds).
set -euo pipefail

postgrest_version=v12.2.12
postgrest_sha256=5de4092f1719da3353c40bf96c8dec6913f2254a7cd0b61cc05f233153b557d5

source "$(dirname "$0")/cluster.sh"
root="$(cd "$here/../.." && pwd)"

postgrest="${MODUSNOTE_POSTGREST:-}"
if [ -z "$postgrest" ]; then
  download="$(mktemp -d)"
  archive="$download/postgrest.tar.xz"
  curl -fsSL -o "$archive" \
    "https://github.com/PostgREST/postgrest/releases/download/$postgrest_version/postgrest-$postgrest_version-linux-static-x86-64.tar.xz"
  echo "$postgrest_sha256  $archive" | sha256sum -c --quiet
  tar -xJf "$archive" -C "$download"
  postgrest="$download/postgrest"
fi

# Supabase's PostgREST logs in as `authenticator` and switches to the role
# named in the JWT.
psql_run -c "create role authenticator login noinherit; grant anon, authenticated to authenticator;"

jwt_secret="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
api_port=54330
PGRST_DB_URI="postgres:///postgres?host=$data&port=$port&user=authenticator" \
PGRST_DB_SCHEMAS=public \
PGRST_DB_ANON_ROLE=anon \
PGRST_JWT_SECRET="$jwt_secret" \
PGRST_SERVER_PORT=$api_port \
PGRST_SERVER_HOST=127.0.0.1 \
  "$postgrest" >"$data/postgrest.log" 2>&1 &
postgrest_pid=$!
stop_postgrest() { kill "$postgrest_pid" 2>/dev/null; wait "$postgrest_pid" 2>/dev/null; }
cleanup_hooks+=(stop_postgrest)

for _ in $(seq 50); do
  curl -fs -o /dev/null "http://127.0.0.1:$api_port/" && break
  sleep 0.2
done

cd "$root/packages/offline_sync_adapters"
MODUSNOTE_POSTGREST_URL="http://127.0.0.1:$api_port" \
MODUSNOTE_JWT_SECRET="$jwt_secret" \
  dart test test/supabase_e2e_test.dart || {
    cat "$data/postgrest.log"
    exit 1
  }
