#!/usr/bin/env bash
# Checks an Android App Bundle before it goes to Google Play:
#   - every 64-bit native library (libsodium, libopus, SoLoud, Flutter) is
#     aligned for 16 KB memory pages, which Play requires of apps targeting
#     API 35 and later;
#   - the bundle has the 64-bit ABIs;
#   - the merged manifest asks for the network and keeps the vault out of
#     Android backups.
# Usage: tool/check_android_bundle.sh build/app/outputs/bundle/release/app-release.aab
set -euo pipefail

bundle=${1:?path to the .aab}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unzip -q "$bundle" -d "$work"

status=0
for abi in arm64-v8a x86_64; do
  if ! ls "$work"/base/lib/"$abi"/*.so >/dev/null 2>&1; then
    echo "missing ABI: $abi"
    status=1
  fi
done

for so in "$work"/base/lib/*/*.so; do
  abi=$(basename "$(dirname "$so")")
  # 32-bit ABIs run on 4 KB pages only; Play checks the 64-bit ones.
  case "$abi" in arm64-v8a | x86_64) ;; *) continue ;; esac
  # The smallest alignment of the loadable segments.
  align=$(readelf -lW "$so" | awk '$1 == "LOAD" { print $NF }' |
    while read -r a; do printf '%d\n' "$a"; done | sort -n | head -1)
  if [ "${align:-0}" -lt 16384 ]; then
    echo "not 16 KB aligned (${align:-none}): $abi/$(basename "$so")"
    status=1
  else
    echo "ok $abi/$(basename "$so") (LOAD align $align)"
  fi
done

manifest="$work/base/manifest/AndroidManifest.xml"
# The bundle's manifest is a protocol buffer; its strings are plain UTF-8.
grep -aq 'android.permission.INTERNET' "$manifest" || {
  echo 'the manifest does not ask for INTERNET'
  status=1
}
grep -aq 'data_extraction_rules' "$manifest" || {
  echo 'the manifest has no data extraction rules'
  status=1
}

exit $status
