# ebook2audiobook desktop (Tauri wrapper)

Native macOS desktop shell around the bundled ebook2audiobook Python engine.

```
desktop/
  ui/index.html          splash / engine-status UI (served by Tauri, no node build)
  src-tauri/             Rust shell (engine supervisor + IPC commands)
  ci/build-payload.sh    builds the cached engine payload (conda env, calibre, voices)
  ci/assemble-macos.sh   injects payload into the tauri .app; makes the APFS dmg
  ci/sign-notarize.sh    Developer ID signing + notarization (secrets from env only)
  Jenkinsfile            CI pipeline (agent: mbook)
```

## Architecture

- The Rust shell (`src-tauri/src/engine.rs`) locates the engine payload under
  `Contents/Resources` (`app/`, `python_env/`, `calibre.app/`, `seed/`),
  seeds first-run data (voices, tessdata) into
  `~/Library/Application Support/ebook2audiobook`, spawns
  `python_env/bin/python -u app.py --script_mode native` with the portable-bundle
  environment (`E2A_BUNDLE=1`), and watches `127.0.0.1:7860`.
- The webview shows `ui/index.html` until the engine is up, then navigates to
  the Gradio UI. Startup failures show the log tail with retry / open-log /
  open-in-browser actions.
- Quitting the app SIGTERMs the engine process tree.

## Local development

```bash
cd desktop/src-tauri
E2A_RESOURCES=/path/to/app-bundle/Contents/Resources cargo tauri dev
```

`E2A_RESOURCES` points at a bundle's Resources dir containing `python_env/`
and `app/` (e.g. the one built by CI or by the earlier manual bundle work).

## CI

Jenkins job `ebook2audiobook` (multibranch, scriptPath `desktop/Jenkinsfile`)
builds on the `mbook` agent:

1. `cargo check` — fast compile gate
2. engine payload, cached by `sha256(requirements.txt, build-payload.sh, VERSION.txt)`
   (miniforge + conda env with torch-mps/ffmpeg/sox/mediainfo/tesseract +
   espeakng-loader + sitecustomize, packed with conda-pack; official Calibre
   dmg; builtin voices)
3. `cargo tauri build --bundles app`
4. payload injection + pre-sign engine smoke test
5. Developer ID signing (hardened runtime + entitlements) and notarization of
   the APFS DMG via App Store Connect API key — credentials
   `apple-signing-identity`, `apple-certificate`, `apple-certificate-password`,
   `apple-api-issuer`, `apple-api-key-id`, `apple-api-key-p8` are injected by
   `withCredentials` and never printed.

Artifacts: `desktop/dist/ebook2audiobook-<version>-macos-arm64.dmg`

### Hard-won details encoded in the scripts

- DMG is APFS, never HFS+ (HFS+ NFD normalization breaks the sealed
  accented filenames in the voices payload).
- `.gitkeep` placeholders are deleted before signing (they break strict
  seal verification).
- `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE`/`FONTCONFIG_*` are pinned into the
  relocated conda env paths (stdlib TLS and fontconfig break otherwise).
