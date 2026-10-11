#!/usr/bin/env bash
# Applies the migrations to a throwaway PostgreSQL cluster and runs the RLS
# tests against it.
set -euo pipefail

source "$(dirname "$0")/cluster.sh"
psql_run -f "$here/rls_test.sql" 2>&1 | sed -n -e 's/.*NOTICE:  //p' -e '/ERROR/p'
echo "RLS tests passed"
