#!/usr/bin/env bash
# Build PuterUse.app (the native helper) into build/.
#
# macOS ties Screen Recording / Accessibility grants to the app's code signature. Ad-hoc signatures
# change on every build (so grants would be lost), so by default we sign with a self-signed identity
# kept in a private keychain file under ~/Library/Application Support/puter-use/signing (it is not
# added to your keychain search list and no trust settings are changed). Set PUTER_USE_SIGN_IDENTITY
# to use your own identity instead, or "-" for ad-hoc.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/PuterUse.app"
identity="${PUTER_USE_SIGN_IDENTITY:-}"
keychain_args=()

if [ -z "$identity" ]; then
  identity="puter-use local signing"
  sdir="$HOME/Library/Application Support/puter-use/signing"
  kc="$sdir/signing.keychain-db"
  if [ ! -f "$kc" ]; then
    mkdir -p "$sdir" && chmod 700 "$sdir"
    /usr/bin/openssl rand -hex 16 > "$sdir/password" && chmod 600 "$sdir/password"
    pw="$(cat "$sdir/password")"
    tmp="$(mktemp -d)"
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$identity" \
      -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
      -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" \
      -passout "pass:$pw" -name "$identity"
    security create-keychain -p "$pw" "$kc"
    security set-keychain-settings "$kc"  # no auto-lock
    security import "$tmp/id.p12" -k "$kc" -P "$pw" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$pw" "$kc" >/dev/null
    rm -rf "$tmp"
  fi
  security unlock-keychain -p "$(cat "$sdir/password")" "$kc"
  keychain_args=(--keychain "$kc")
fi

swift build -c release --package-path "$root/helper" >&2
bin="$(swift build -c release --package-path "$root/helper" --show-bin-path)/PuterUseHelper"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/PuterUseHelper"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.puter-use.helper</string>
  <key>CFBundleName</key><string>PuterUse</string>
  <key>CFBundleDisplayName</key><string>PuterUse</string>
  <key>CFBundleExecutable</key><string>PuterUseHelper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign "$identity" ${keychain_args[@]+"${keychain_args[@]}"} --identifier dev.puter-use.helper "$app" >&2
echo "$app"
