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
# Keychain must live directly under $HOME (as in the proven redrafter recipe),
# not in the workspace — workspace-located keychains accept certificates but
# not private keys on this agent.
KC="$HOME/e2a-signing.keychain-db"
KC_PASS="$(openssl rand -base64 24)"
cleanup() {
  rm -f "$CERT_TMP"
  if [ -n "${ORIG_KEYCHAINS:-}" ]; then
    security list-keychains -d user -s $ORIG_KEYCHAINS 2>/dev/null || true
  fi
  security delete-keychain "$KC" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------------------------------------------- keychain
# Recipe proven by the redrafter pipeline on the same agent: a dedicated,
# UNLOCKED keychain + the Developer ID G2 intermediate (macOS ships the root
# but not G2, so a keychain with only the leaf cannot build the chain) + an
# explicit partition list with -s (headless codesign access, else
# errSecInternalComponent). Importing into a locked keychain silently drops
# the private key (certs import, key does not).
if [ "${SIGN_MODE:-developer-id}" = "adhoc" ]; then
  echo "=== SIGN_MODE=adhoc: skipping Developer ID keychain setup ==="
else
echo "=== preparing signing keychain ==="
ORIG_KEYCHAINS="$(security list-keychains -d user | sed 's/[" ]//g')"
security delete-keychain "$KC" >/dev/null 2>&1 || true
security create-keychain -p "$KC_PASS" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KC_PASS" "$KC"
security list-keychains -d user -s "$KC" $ORIG_KEYCHAINS

echo "=== installing Developer ID G2 intermediate (chain completion) ==="
G2_TMP="$(mktemp -d)/DeveloperIDG2CA.cer"
curl -fsSL -o "$G2_TMP" https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
security import "$G2_TMP" -k "$KC" -T /usr/bin/codesign
rm -f "$G2_TMP"

printf '%s' "$APPLE_CERT" > "$CERT_TMP"
import_log="$(mktemp)"
import_ok=0
run_import() { security import "$@" >>"$import_log" 2>&1; }
if head -c 11 "$CERT_TMP" | grep -q '^-----BEGIN'; then
  # PEM: try with password first (encrypted key), then unencrypted.
  run_import "$CERT_TMP" -k "$KC" -P "$APPLE_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security \
    || run_import "$CERT_TMP" -k "$KC" -T /usr/bin/codesign -T /usr/bin/security \
    || import_ok=1
else
  # Assume base64-encoded .p12. security(1) sniffs the container by file
  # EXTENSION — a suffixless temp file yields "Unknown format in import".
  # openssl base64 -d -A matches the proven recipe (single-line input).
  B64_DIR="$(mktemp -d)"
  B64_TMP="$B64_DIR/devid.p12"
  if ! printf '%s' "$APPLE_CERT" | openssl base64 -d -A > "$B64_TMP" 2>>"$import_log"; then
    echo "FATAL: base64 decode of certificate failed" >&2
    cat "$import_log" >&2
    rm -rf "$B64_DIR"
    exit 1
  fi
  run_import "$B64_TMP" -k "$KC" -P "$APPLE_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security || import_ok=1
  rm -rf "$B64_DIR"
fi
echo "import summary: $(grep -E 'imported|identity' "$import_log" | tail -2 | tr '\n' ' ')"
if [ "$import_ok" -ne 0 ]; then
  echo "FATAL: certificate import failed — security output follows (contains no secret material):" >&2
  cat "$import_log" >&2
  rm -f "$import_log"
  exit 1
fi
rm -f "$import_log"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null

count_identities() { # keychain-or-empty, [policy]
  local kc="$1" pol="${2:-}"
  local out n
  if [ -n "$pol" ]; then
    out="$(security find-identity -v -p "$pol" ${kc:+"$kc"} 2>/dev/null)"
  else
    out="$(security find-identity -v ${kc:+"$kc"} 2>/dev/null)"
  fi
  n="$(printf '%s\n' "$out" | grep -E '[0-9]+ valid identit' | head -1 | awk '{print $1}')"
  echo "${n:-0}"
}
IDENTITY_ALL="$(count_identities "$KC")"
IDENTITY_CS="$(count_identities "$KC" codesigning)"
CERT_COUNT="$(security find-certificate -a "$KC" 2>/dev/null | grep -c '"alis"' || echo 0)"
KEY_COUNT="$(security find-key "$KC" 2>/dev/null | grep -c '"labl"' || echo 0)"
echo "keychain contents: certs=${CERT_COUNT} keys=${KEY_COUNT} identities(all)=${IDENTITY_ALL} identities(codesigning)=${IDENTITY_CS}"
# Raw find-identity output (identity names are masked by Jenkins if they match
# credential values; nothing secret is printed by security here).
security find-identity -v -p codesigning "$KC" 2>&1 | tail -3

# The p12 may be certificates-only (private key provisioned separately on the
# agent). Fall back to the agent user's own keychain search list.
LOGIN_CS="$(count_identities "" codesigning)"
echo "agent keychain identities(codesigning)=${LOGIN_CS}"
if [ "${IDENTITY_CS:-0}" -lt 1 ] && [ "${LOGIN_CS:-0}" -lt 1 ]; then
  # Diagnostic: does the p12 itself carry a private key? (count only)
  KEYS_IN_P12="$(printf '%s' "$APPLE_CERT" | base64 -D \
    | openssl pkcs12 -nocerts -nodes -passin pass:"$APPLE_CERT_PASSWORD" 2>/dev/null \
    | grep -c 'PRIVATE KEY' || true)"
  echo "private keys contained in the p12: ${KEYS_IN_P12}"
  echo "FATAL: no valid codesigning identity after import" >&2
  if [ "${KEYS_IN_P12:-0}" -lt 1 ]; then
    echo "  -> the apple-certificate credential may lack its private key," >&2
    echo "     or apple-certificate-password does not match the p12 export." >&2
  fi
  exit 1
fi
echo "keychain ready (identities present; names withheld)"
fi # end SIGN_MODE=developer-id keychain setup

# ---------------------------------------------------------------- codesign
echo "=== signing app (mode=${SIGN_MODE:-developer-id}) ==="
if [ "${SIGN_MODE:-developer-id}" = "adhoc" ]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime \
    --sign "$APPLE_SIGNING_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --timestamp \
    "$APP"
fi

codesign --verify --deep --strict "$APP" && echo "signature: valid"
if [ "${SIGN_MODE:-developer-id}" != "adhoc" ] && codesign -dvv "$APP" 2>&1 | grep -q "flags=0x2(adhoc)"; then
  echo "FATAL: signature is adhoc — Developer ID signing did not take effect" >&2
  exit 1
fi

# ---------------------------------------------------------------- dmg + notarize
echo "=== creating APFS dmg ==="
"$(dirname "$0")/assemble-macos.sh" dmg "$APP" "$OUT_DMG"

if [ "${SIGN_MODE:-developer-id}" = "adhoc" ] || [ "${SKIP_NOTARIZATION:-0}" = "1" ]; then
  echo "=== skipping notarization (SIGN_MODE=${SIGN_MODE:-developer-id} SKIP_NOTARIZATION=${SKIP_NOTARIZATION:-0}) ==="
else
  echo "=== submitting for notarization ==="
  NOTARY_OUT="$(mktemp)"
  if xcrun notarytool submit "$OUT_DMG" \
    --key "$APPLE_API_KEY_P8" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER" \
    --wait --timeout 30m 2>&1 | tee "$NOTARY_OUT"; then
    if grep -q "status: Accepted" "$NOTARY_OUT"; then
      echo "=== stapling ==="
      xcrun stapler staple "$OUT_DMG"
      xcrun stapler validate "$OUT_DMG" && echo "notarization: stapled + valid"
    else
      echo "=== notarization NOT accepted — fetching service log ==="
      SUBMIT_ID="$(grep -oE 'id: [0-9a-f-]{36}' "$NOTARY_OUT" | head -1 | cut -d' ' -f2)"
      if [ -n "$SUBMIT_ID" ]; then
        xcrun notarytool log "$SUBMIT_ID" \
          --key "$APPLE_API_KEY_P8" \
          --key-id "$APPLE_API_KEY_ID" \
          --issuer "$APPLE_API_ISSUER" 2>/dev/null \
          | python3 -c "import json,sys; d=json.load(sys.stdin); [print(i.get('severity',''), '|', i.get('path','(app)'), '|', i.get('message','')) for i in d.get('issues',[])]" \
          || echo "(log fetch failed)"
      fi
      rm -f "$NOTARY_OUT"
      echo "FATAL: notarization was not accepted" >&2
      exit 1
    fi
  else
    echo "=== notarytool submit/wait failed ==="
    cat "$NOTARY_OUT" >&2
    rm -f "$NOTARY_OUT"
    exit 1
  fi
  rm -f "$NOTARY_OUT"
fi

echo "=== artifact ==="
du -sh "$OUT_DMG"
shasum -a 256 "$OUT_DMG"
