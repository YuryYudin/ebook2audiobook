#!/bin/bash
# Signs the assembled app with a Developer ID certificate and notarizes the
# DMG via the App Store Connect API key.
#
# All secrets arrive as environment variables injected by the Jenkins
# `withCredentials` block; this script never prints them.
#   APPLE_SIGNING_IDENTITY   codesign identity name (secret text)
#   APPLE_CERT               certificate (secret text: PEM or base64 .p12)
#   APPLE_CERT_PASSWORD      certificate password (secret text)
#   APPLE_API_ISSUER         notarytool --issuer (secret text)
#   APPLE_API_KEY_ID         notarytool --key-id (secret text)
#   APPLE_API_KEY_P8         notarytool --key (secret file)
#   APP / OUT_DMG            paths of app and dmg
set -euo pipefail

APP="${APP:?APP (path to assembled .app) required}"
OUT_DMG="${OUT_DMG:?OUT_DMG required}"
ENTITLEMENTS="$(cd "$(dirname "$0")/.." && pwd)/src-tauri/entitlements.plist"

CERT_TMP="$(mktemp)"
KC="$PWD/e2a-sign.keychain-db"
KC_PASS="$(openssl rand -hex 24 2>/dev/null || head -c 48 /dev/urandom | xxhsum | cut -d' ' -f1 || true)"
[ -n "$KC_PASS" ] || { echo "FATAL: cannot generate keychain password"; exit 1; }
cleanup() {
  rm -f "$CERT_TMP"
  security delete-keychain "$KC" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------------------------------------------- keychain
echo "=== preparing signing keychain ==="
security delete-keychain "$KC" >/dev/null 2>&1 || true
security create-keychain -p "$KC_PASS" "$KC"
security set-keychain-settings -lut 21600 "$KC"

printf '%s' "$APPLE_CERT" > "$CERT_TMP"
import_log="$(mktemp)"
import_ok=0
if head -c 11 "$CERT_TMP" | grep -q '^-----BEGIN'; then
  # PEM: try with password first (encrypted key), then unencrypted.
  if ! security import "$CERT_TMP" -k "$KC" -P "$APPLE_CERT_PASSWORD" -T /usr/bin/codesign >"$import_log" 2>&1; then
    security import "$CERT_TMP" -k "$KC" -T /usr/bin/codesign >>"$import_log" 2>&1 || import_ok=1
  fi
else
  # Assume base64-encoded .p12. security(1) sniffs the container by file
  # EXTENSION — a suffixless temp file yields "Unknown format in import".
  # macOS base64 decode flag is -D.
  B64_DIR="$(mktemp -d)"
  B64_TMP="$B64_DIR/cert.p12"
  if ! printf '%s' "$APPLE_CERT" | base64 -D > "$B64_TMP" 2>>"$import_log"; then
    echo "FATAL: base64 decode of certificate failed" >&2
    cat "$import_log" >&2
    rm -rf "$B64_DIR"
    exit 1
  fi
  CERT_KIND="$(file -b "$B64_TMP")"
  echo "decoded certificate kind: ${CERT_KIND%%,*}"
  security import "$B64_TMP" -k "$KC" -P "$APPLE_CERT_PASSWORD" -T /usr/bin/codesign >>"$import_log" 2>&1 || import_ok=1
  rm -rf "$B64_DIR"
fi
if [ "$import_ok" -ne 0 ]; then
  echo "FATAL: certificate import failed — security output follows (contains no secret material):" >&2
  cat "$import_log" >&2
  rm -f "$import_log"
  exit 1
fi
rm -f "$import_log"
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
security set-key-partition-list -S apple-tool:,apple: -k "$KC_PASS" "$KC" >/dev/null

IDENTITY_COUNT="$(security find-identity -p codesigning -v "$KC" 2>/dev/null | tail -1 | grep -oE '^[0-9]+' || echo 0)"
if [ "${IDENTITY_COUNT:-0}" -lt 1 ]; then
  echo "FATAL: no valid codesigning identity after import" >&2
  exit 1
fi
echo "keychain ready (identities present; names withheld)"

# ---------------------------------------------------------------- codesign
echo "=== signing app (Developer ID, hardened runtime) ==="
codesign --force --deep --options runtime \
  --sign "$APPLE_SIGNING_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  --timestamp \
  "$APP"

codesign --verify --deep --strict "$APP" && echo "signature: valid"
if codesign -dvv "$APP" 2>&1 | grep -q "flags=0x2(adhoc)"; then
  echo "FATAL: signature is adhoc — Developer ID signing did not take effect" >&2
  exit 1
fi

# ---------------------------------------------------------------- dmg + notarize
echo "=== creating APFS dmg ==="
"$(dirname "$0")/assemble-macos.sh" dmg "$APP" "$OUT_DMG"

if [ "${SKIP_NOTARIZATION:-0}" = "1" ]; then
  echo "=== skipping notarization (SKIP_NOTARIZATION=1) ==="
else
  echo "=== submitting for notarization ==="
  xcrun notarytool submit "$OUT_DMG" \
    --key "$APPLE_API_KEY_P8" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER" \
    --wait --timeout 30m
  echo "=== stapling ==="
  xcrun stapler staple "$OUT_DMG"
  xcrun stapler validate "$OUT_DMG" && echo "notarization: stapled + valid"
fi

echo "=== artifact ==="
du -sh "$OUT_DMG"
shasum -a 256 "$OUT_DMG"
