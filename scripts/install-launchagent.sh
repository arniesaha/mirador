#!/usr/bin/env bash
set -euo pipefail

# Modes:
#   install   (default)  build + sign + (re)write plist + bootstrap + kickstart
#   build                build + sign the binary only (no launchd changes)
#   restart   (reload)   kickstart the loaded service WITHOUT rebuilding or
#                        re-signing — never invalidates TCC permissions
#
# Signing: if a stable identity is available (see scripts/setup-signing-identity.sh
# or MIRADOR_SIGN_IDENTITY) the binary is signed with it, so macOS Screen Recording
# and Accessibility grants survive rebuilds. Otherwise it falls back to ad-hoc
# signing with a warning — ad-hoc builds lose those grants on every rebuild.

mode="${1:-install}"

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
template_plist="$repo_root/launchd/com.mirador.host.plist"
binary_path="$repo_root/bin/mirador"
domain="gui/$(id -u)"
service="$domain/com.mirador.host"

account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //' || true)"
if [[ -z "$account_home" ]]; then
  account_home="$HOME"
fi
launch_agents_dir="$account_home/Library/LaunchAgents"
installed_plist="$launch_agents_dir/com.mirador.host.plist"
token_file="$account_home/.mirador-token"
legacy_profile_plist="$HOME/Library/LaunchAgents/com.mirador.host.plist"

signing_keychain="$account_home/Library/Keychains/mirador-signing.keychain-db"
signing_keychain_pw_file="$account_home/.mirador-signing-keychain-password"
signing_identity_name="${MIRADOR_SIGN_IDENTITY_NAME:-Mirador Development}"

clear_launchctl_xattrs() {
  local path="$1"
  xattr -d com.apple.quarantine "$path" 2>/dev/null || true
  xattr -d com.apple.provenance "$path" 2>/dev/null || true
  xattr -c "$path" 2>/dev/null || true
}

# Echoes the codesign identity to use ("-" for ad-hoc) and prepares the signing
# keychain (unlock + search list) when a stable identity is present.
resolve_sign_identity() {
  if [[ -n "${MIRADOR_SIGN_IDENTITY:-}" ]]; then
    printf '%s' "$MIRADOR_SIGN_IDENTITY"
    return 0
  fi
  if [[ -f "$signing_keychain" && -s "$signing_keychain_pw_file" ]]; then
    local pw
    pw="$(tr -d '\n\r' < "$signing_keychain_pw_file")"
    security unlock-keychain -p "$pw" "$signing_keychain" 2>/dev/null || true
    if ! security list-keychains -d user | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//' | grep -qxF "$signing_keychain"; then
      local current
      current="$(security list-keychains -d user | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//')"
      # shellcheck disable=SC2086
      security list-keychains -d user -s "$signing_keychain" $current
    fi
    if security find-identity -p codesigning "$signing_keychain" | grep -qF "$signing_identity_name"; then
      printf '%s' "$signing_identity_name"
      return 0
    fi
  fi
  printf '%s' "-"
}

sign_binary() {
  local identity
  identity="$(resolve_sign_identity)"
  if [[ "$identity" == "-" ]]; then
    printf 'WARNING: signing ad-hoc — macOS will drop Screen Recording and Accessibility\n' >&2
    printf '         grants on every rebuild. Run scripts/setup-signing-identity.sh once\n' >&2
    printf '         for a stable identity that keeps permissions across rebuilds.\n' >&2
    codesign --force --sign - --identifier com.mirador.host "$binary_path"
  else
    printf 'Signing with stable identity: %s\n' "$identity" >&2
    codesign --force --sign "$identity" --identifier com.mirador.host --keychain "$signing_keychain" "$binary_path"
  fi
  clear_launchctl_xattrs "$binary_path"
}

build_binary() {
  cd "$repo_root"
  swift build -c release
  mkdir -p "$repo_root/bin"
  cp "$repo_root/.build/release/mirador" "$binary_path"
  sign_binary
}

ensure_token() {
  mkdir -p "$launch_agents_dir"
  if [[ ! -s "$token_file" ]]; then
    python3 - <<'PY' > "$token_file"
import secrets
print(secrets.token_urlsafe(32))
PY
    chmod 600 "$token_file"
  fi
}

bootstrap_service() {
  set +e
  local output
  output="$(launchctl bootstrap "$domain" "$installed_plist" 2>&1)"
  local status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    return 0
  fi

  printf '%s\n' "$output" >&2
  if [[ "$output" == *"Input/output error"* || "$output" == *"Bootstrap failed: 5"* ]]; then
    printf 'Retrying launchctl bootstrap after clearing macOS xattrs from plist and binary...\n' >&2
    clear_launchctl_xattrs "$installed_plist"
    clear_launchctl_xattrs "$binary_path"
    launchctl bootstrap "$domain" "$installed_plist"
    return 0
  fi

  return "$status"
}

install_service() {
  local mirador_token
  mirador_token="$(tr -d '\n\r' < "$token_file")"
  local tmp_plist
  tmp_plist="$(mktemp "${TMPDIR:-/tmp}/com.mirador.host.plist.XXXXXX")"
  trap 'rm -f "$tmp_plist"' RETURN

  MIRADOR_TEMPLATE_PLIST="$template_plist" \
  MIRADOR_OUTPUT_PLIST="$tmp_plist" \
  MIRADOR_BINARY_PATH="$binary_path" \
  MIRADOR_TOKEN="$mirador_token" \
  python3 - <<'PY'
import os
import plistlib

with open(os.environ["MIRADOR_TEMPLATE_PLIST"], "rb") as source:
    plist = plistlib.load(source)

arguments = plist.get("ProgramArguments")
if not isinstance(arguments, list) or not arguments:
    raise SystemExit("template plist is missing ProgramArguments")

arguments[0] = os.environ["MIRADOR_BINARY_PATH"]
plist.setdefault("EnvironmentVariables", {})["MIRADOR_TOKEN"] = os.environ["MIRADOR_TOKEN"]

with open(os.environ["MIRADOR_OUTPUT_PLIST"], "wb") as destination:
    plistlib.dump(plist, destination)
PY

  set +e
  local bootout_output bootout_status
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

  cp "$tmp_plist" "$installed_plist"
  chmod 644 "$installed_plist"
  clear_launchctl_xattrs "$installed_plist"
  if [[ "$legacy_profile_plist" != "$installed_plist" ]]; then
    rm -f "$legacy_profile_plist"
  fi
  bootstrap_service
  launchctl enable "$service"
  launchctl kickstart -k "$service"
  launchctl print "$service" | sed -E 's/(MIRADOR_TOKEN=)[^[:space:]]+/\1***/g'
}

restart_service() {
  if ! launchctl print "$service" >/dev/null 2>&1; then
    printf 'Service %s is not loaded; run "%s install" first.\n' "$service" "$0" >&2
    exit 1
  fi
  launchctl kickstart -k "$service"
  printf 'Restarted %s (no rebuild/re-sign — TCC permissions preserved).\n' "$service"
}

case "$mode" in
  build)
    build_binary
    ;;
  restart|reload)
    restart_service
    ;;
  install|"")
    build_binary
    ensure_token
    install_service
    ;;
  -h|--help|help)
    printf 'usage: %s [install|build|restart]\n' "$0"
    ;;
  *)
    printf 'unknown mode: %s\nusage: %s [install|build|restart]\n' "$mode" "$0" >&2
    exit 2
    ;;
esac
