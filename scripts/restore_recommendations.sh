#!/bin/sh
# Restore the two package overrides captured for this TV build. APK/data are untouched.
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || [ -z "$1" ]; then
  echo "Usage: sh scripts/restore_recommendations.sh <adb-serial> [--apply]" >&2
  exit 2
fi
case "$1" in -*) echo "An explicit ADB serial is required." >&2; exit 2 ;; esac
case "${2:-}" in ""|--apply) ;; *) echo "Only --apply is supported." >&2; exit 2 ;; esac

serial="$1"
if [ "$(adb -s "$serial" get-state)" != device ]; then
  echo "The selected device is not authorized/connected; nothing changed." >&2
  exit 1
fi
expected='Metz/Metz_EU/shinagawa:11/RTO9.250817.002/13948470:user/release-keys'
if [ "$(adb -s "$serial" shell getprop ro.build.fingerprint | tr -d '\r')" != "$expected" ]; then
  echo "TV build differs from the captured baseline; nothing changed." >&2
  exit 1
fi
installed="$(adb -s "$serial" shell pm list packages --user 0 | tr -d '\r')"
for package in com.google.android.tvrecommendations tv.anoki.acr.controller; do
  if ! printf '%s\n' "$installed" | grep -Fqx "package:$package"; then
    echo "Expected package missing: $package; nothing changed." >&2
    exit 1
  fi
done

for package in com.google.android.tvrecommendations tv.anoki.acr.controller; do
  if [ "${2:-}" = --apply ]; then
    adb -s "$serial" shell pm default-state --user 0 "$package"
  else
    echo "Dry run: pm default-state --user 0 $package"
  fi
done
