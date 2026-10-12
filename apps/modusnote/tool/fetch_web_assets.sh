#!/usr/bin/env bash
# Downloads the two WebAssembly libraries the web client loads, each checked
# against a pinned hash, into web/. The files are committed, so a build never
# needs the network; run this only when `sodium` or `sqlite3` is upgraded,
# then update the hashes below and in test/platform/web_assets_test.dart.
set -euo pipefail
cd "$(dirname "$0")/.."

# libsodium.js sumo: the `sodium` package downloads the build matching its own
# libsodium version and verifies the SHA-512 it ships with.
dart run sodium:update_web --sumo --no-edit-index --target-directory web

# SQLite for package:sqlite3/wasm.dart: must match the sqlite3 package version.
SQLITE3_VERSION=3.7.0
SQLITE3_WASM_SHA256=fbcd2e8214f9231ea961e1b7706a22dd1194cfbfe6f26f13841b5aa7a0be1a1f
curl -sSfL -o web/sqlite3.wasm.part \
  "https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-${SQLITE3_VERSION}/sqlite3.wasm"
echo "${SQLITE3_WASM_SHA256}  web/sqlite3.wasm.part" | sha256sum -c -
mv web/sqlite3.wasm.part web/sqlite3.wasm
