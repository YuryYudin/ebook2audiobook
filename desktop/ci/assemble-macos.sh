#!/bin/bash
# Assembles the distributable macOS app and (mode: dmg) the APFS disk image.
#
# Usage:
#   assemble-macos.sh app   <bare.app> <payload_dir> <src_dir>
#       Injects the engine payload into the tauri-built .app and runs a
#       pre-sign engine smoke test.
#   assemble-macos.sh dmg   <signed.app> <out.dmg>
#       Creates a compressed APFS DMG (APFS keeps unicode names byte-exact,
#       which HFS+ NFD normalization would break — required for the sealed
#       resources of the signed bundle).
set -euo pipefail

MODE="${1:?usage: assemble-macos.sh app|dmg ...}"

case "$MODE" in
app)
  BARE_APP="${2:?bare .app path required}"
  PAYLOAD_DIR="${3:?payload dir required}"
  SRC_DIR="${4:?src dir required}"

  RES="$BARE_APP/Contents/Resources"
  rm -rf "$RES/app" "$RES/python_env" "$RES/calibre.app" "$RES/seed"
  mkdir -p "$RES/app" "$RES/seed/tessdata"

  echo "=== injecting engine source ==="
  rsync -a \
    "$SRC_DIR/app.py" "$SRC_DIR/lib" "$SRC_DIR/VERSION.txt" \
    "$SRC_DIR/requirements.txt" "$SRC_DIR/favicon.ico" "$SRC_DIR/LICENSE" \
    "$RES/app/"

  echo "=== injecting python_env ==="
  mkdir -p "$RES/python_env"
  tar -xzf "$PAYLOAD_DIR/python_env.tar.gz" -C "$RES/python_env"

  echo "=== injecting calibre ==="
  ditto "$PAYLOAD_DIR/calibre.app" "$RES/calibre.app"

  echo "=== injecting seed data ==="
  ditto "$PAYLOAD_DIR/voices" "$RES/seed/voices"
  cp "$RES/python_env/share/tessdata/eng.traineddata" "$RES/seed/tessdata/"
  cp "$RES/python_env/share/tessdata/osd.traineddata" "$RES/seed/tessdata/"

  # Placeholder files must not exist in the sealed bundle (they have proven
  # fragile across copies and invalidate strict codesign verification).
  echo "=== removing .gitkeep placeholders ==="
  find "$RES" -name ".gitkeep" -type f -delete

  echo "=== pre-sign engine smoke test ==="
  SMOKE_HOME="$(mktemp -d)"
  trap 'rm -rf "$SMOKE_HOME"' EXIT
  E2A_BUNDLE=1 \
  E2A_HOME="$SMOKE_HOME" \
  PATH="$RES/python_env/bin:$RES/calibre.app/Contents/MacOS:/usr/bin:/bin:/usr/sbin:/sbin" \
  SSL_CERT_FILE="$RES/python_env/ssl/cacert.pem" \
  REQUESTS_CA_BUNDLE="$RES/python_env/ssl/cacert.pem" \
  FONTCONFIG_FILE="$RES/python_env/etc/fonts/fonts.conf" \
  PYTHONUTF8=1 PYTHONIOENCODING=utf-8 \
    "$RES/python_env/bin/python" "$RES/app/app.py" --version
  rm -rf "$SMOKE_HOME"
  trap - EXIT

  echo "=== assembled: $BARE_APP ==="
  du -sh "$BARE_APP"
  ;;

dmg)
  SIGNED_APP="${2:?signed .app path required}"
  OUT_DMG="${3:?output dmg path required}"
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT

  ditto "$SIGNED_APP" "$STAGE/ebook2audiobook.app"
  ln -sfn /Applications "$STAGE/Applications"
  for ICON in AppIcon.icns appIcon.icns icon.icns; do
    if [ -f "$SIGNED_APP/Contents/Resources/$ICON" ]; then
      cp "$SIGNED_APP/Contents/Resources/$ICON" "$STAGE/.VolumeIcon.icns"
      break
    fi
  done

  rm -f "$OUT_DMG"
  # APFS (NOT HFS+): HFS+ unicode normalization (NFD) mangles accented
  # filenames that were sealed NFC at signing time, breaking the code
  # signature after drag-out from the image.
  hdiutil create -fs "APFS" -format UDZO -imagekey zlib-level=9 \
    -volname "ebook2audiobook" -srcfolder "$STAGE" -ov "$OUT_DMG" >/dev/null
  hdiutil verify "$OUT_DMG" | tail -1
  du -sh "$OUT_DMG"
  ;;

*)
  echo "unknown mode: $MODE" >&2
  exit 1
  ;;
esac
