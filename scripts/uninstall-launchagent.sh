#!/usr/bin/env bash
set -euo pipefail

service="gui/$(id -u)/com.mirador.host"

account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //' || true)"
if [[ -z "$account_home" ]]; then
  account_home="$HOME"
fi
installed_plist="$account_home/Library/LaunchAgents/com.mirador.host.plist"
legacy_profile_plist="$HOME/Library/LaunchAgents/com.mirador.host.plist"

set +e
bootout_output="$(launchctl bootout "$service" 2>&1)"
bootout_status=$?
set -e
if [[ $bootout_status -ne 0 ]]; then
  if [[ $bootout_status -eq 3 && "$bootout_output" == *"No such process"* ]]; then
    : # Not loaded; safe to continue.
  else
    printf '%s\n' "$bootout_output" >&2
    exit "$bootout_status"
  fi
fi

rm -f "$installed_plist"
if [[ "$legacy_profile_plist" != "$installed_plist" ]]; then
  rm -f "$legacy_profile_plist"
fi
