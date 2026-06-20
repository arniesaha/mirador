#!/usr/bin/env bash
set -euo pipefail

# Creates a stable, self-signed code-signing identity for mirador development builds
# so macOS TCC (Screen Recording, Accessibility) grants survive rebuilds.
#
# Why this exists: ad-hoc signing (`codesign --sign -`) produces a new code
# directory hash on every build, and TCC treats each hash as a different program,
# so every deploy lost its permissions. A self-signed identity gives every build
# the same designated requirement (keyed on the certificate), so a single grant
# persists across rebuilds.
#
# The identity lives in a dedicated keychain with a known password (stored 0600)
# so the deploy script can sign non-interactively, without touching the login
# keychain. Run this once; it is idempotent.

identity_name="${MIRADOR_SIGN_IDENTITY_NAME:-Mirador Development}"
identifier="${MIRADOR_SIGN_IDENTIFIER:-com.mirador.host}"

account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //' || true)"
if [[ -z "$account_home" ]]; then
  account_home="$HOME"
fi
keychain="$account_home/Library/Keychains/mirador-signing.keychain-db"
keychain_pw_file="$account_home/.mirador-signing-keychain-password"
openssl_bin="/usr/bin/openssl" # LibreSSL: emits PKCS#12 that `security import` reads natively

in_search_list() {
  security list-keychains -d user \
    | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//' \
    | grep -qxF "$1"
}

ensure_in_search_list() {
  local target="$1"
  if in_search_list "$target"; then
    return 0
  fi
  local current
  current="$(security list-keychains -d user | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//')"
  # shellcheck disable=SC2086 -- intentional word-splitting of existing keychain paths
  security list-keychains -d user -s "$target" $current
}

# Already set up? Make sure it is usable, then stop.
if [[ -f "$keychain" && -s "$keychain_pw_file" ]]; then
  pw="$(tr -d '\n\r' < "$keychain_pw_file")"
  security unlock-keychain -p "$pw" "$keychain" 2>/dev/null || true
  ensure_in_search_list "$keychain"
  # NOTE: no -v. The cert is self-signed/untrusted, so the "valid identities only"
  # filter hides it, but codesign signs with it fine and that is all we need.
  if security find-identity -p codesigning "$keychain" | grep -qF "$identity_name"; then
    echo "Signing identity already present: $identity_name"
    echo "  keychain: $keychain"
    exit 0
  fi
fi

echo "Creating stable code-signing identity: $identity_name"

work="$(mktemp -d "${TMPDIR:-/tmp}/mirador-signing.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Generate the keychain password if we do not have one yet.
if [[ ! -s "$keychain_pw_file" ]]; then
  python3 - <<'PY' > "$keychain_pw_file"
import secrets
print(secrets.token_urlsafe(24))
PY
  chmod 600 "$keychain_pw_file"
fi
keychain_pw="$(tr -d '\n\r' < "$keychain_pw_file")"

# Self-signed leaf certificate with a code-signing EKU. A config file keeps the
# extensions portable across the system LibreSSL and Homebrew OpenSSL.
cat > "$work/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $identity_name
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

"$openssl_bin" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$work/key.pem" -out "$work/cert.pem" -config "$work/openssl.cnf"
"$openssl_bin" pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
  -out "$work/identity.p12" -passout pass:mirador -name "$identity_name"

# Create the dedicated keychain (skip if it already exists) and import the identity.
if [[ ! -f "$keychain" ]]; then
  security create-keychain -p "$keychain_pw" "$keychain"
fi
security set-keychain-settings "$keychain"            # no auto-lock timeout
security unlock-keychain -p "$keychain_pw" "$keychain"
security import "$work/identity.p12" -k "$keychain" -P mirador -T /usr/bin/codesign -A
# Allow codesign to use the private key without an interactive prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_pw" "$keychain" >/dev/null 2>&1 || true
ensure_in_search_list "$keychain"

echo
security find-identity -p codesigning "$keychain" | grep -F "$identity_name" || true
echo
echo "Done. Build/deploy with:  ./scripts/install-launchagent.sh"
echo "Signs as '$identity_name' (identifier $identifier); TCC grants now survive rebuilds."
