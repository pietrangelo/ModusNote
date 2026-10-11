# Sourced by the test scripts: starts a throwaway PostgreSQL cluster with the
# Supabase stubs and the migrations applied, and stops it on exit. Needs the
# PostgreSQL server binaries (initdb, pg_ctl).

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="$(pg_config --bindir 2>/dev/null || true)"
if [ ! -x "$bin/initdb" ]; then
  bin="$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)"
fi

data="$(mktemp -d)"
port=54329
as_owner=()
if [ "$(id -u)" = 0 ]; then
  # initdb refuses to run as root.
  chown postgres "$data"
  as_owner=(runuser -u postgres --)
fi
cleanup_hooks=()
cleanup() {
  for hook in "${cleanup_hooks[@]}"; do "$hook" || true; done
  "${as_owner[@]}" "$bin/pg_ctl" -D "$data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$data"
}
trap cleanup EXIT

"${as_owner[@]}" "$bin/initdb" -D "$data" -U postgres --auth=trust >/dev/null
"${as_owner[@]}" "$bin/pg_ctl" -D "$data" -o "-p $port -k $data -c listen_addresses=''" -w start >/dev/null

psql_run() {
  psql -X -q -v ON_ERROR_STOP=1 -h "$data" -p "$port" -U postgres -d postgres "$@"
}
psql_run -f "$here/auth_stub.sql"
for migration in "$here"/../migrations/*.sql; do
  psql_run -f "$migration"
done
