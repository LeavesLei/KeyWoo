#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${_KEYWOO_BUILD_LOCK_ROOT:-}" != "$ROOT" ]]; then
  exec python3 "$ROOT/scripts/build-locked.py" "$@"
fi
cd "$ROOT"
CONFIG="${1:-release}"
if [[ "$CONFIG" != release && "$CONFIG" != debug ]]; then
  echo "Usage: scripts/build-app.sh [release|debug]" >&2
  exit 2
fi
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache"
OUTPUT_DIR="${KEYWOO_BUILD_OUTPUT_DIR:-$ROOT/dist}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$ROOT/.build/spm-cache" "$OUTPUT_DIR"
python3 "$ROOT/scripts/prepare-assets.py"
python3 "$ROOT/scripts/release-version.py" --check
# The signing identity is explicit and persistent. Never replace a trusted app
# with a fresh ad-hoc identity just because a certificate/profile is missing.
python3 "$ROOT/scripts/sign-app.py" --check
python3 "$ROOT/scripts/build-receipt.py" "$ROOT/.build/build-source.json"
swift build --disable-sandbox --cache-path "$ROOT/.build/spm-cache" --scratch-path "$ROOT/.build" -c "$CONFIG" -Xswiftc -module-cache-path -Xswiftc "$CLANG_MODULE_CACHE_PATH"
TARGET_APP="$OUTPUT_DIR/KeyWoo.app"
if [[ -L "$TARGET_APP" || ( -e "$TARGET_APP" && ! -d "$TARGET_APP" ) ]]; then
  echo "Refusing to replace a non-directory app path: $TARGET_APP" >&2
  exit 1
fi

# Build and sign a fresh bundle. Overwriting an existing executable in place can
# leave the kernel's code-signature cache associated with the old inode.
# https://developer.apple.com/documentation/security/updating-mac-software
STAGING_ROOT="$(mktemp -d "$OUTPUT_DIR/.KeyWoo-build.XXXXXX")"
trap 'rm -rf -- "$STAGING_ROOT"' EXIT
APP="$STAGING_ROOT/KeyWoo.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/$CONFIG/KeyDance" "$APP/Contents/MacOS/KeyDance"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>KeyWoo</string>
<key>CFBundleDisplayName</key><string>键舞</string>
<key>CFBundleIdentifier</key><string>app.keydance.mac</string>
<key>CFBundleVersion</key><string>0</string>
<key>CFBundleShortVersionString</key><string>0.0.0</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
<key>CFBundleExecutable</key><string>KeyDance</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSInputMonitoringUsageDescription</key><string>在其他应用打字时提供敲击反馈，并在本机统计各键的次数。不记录输入文字。</string>
</dict></plist>
PLIST
python3 "$ROOT/scripts/release-version.py" --plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj" "$APP/Contents/Resources/en.lproj"
cat > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleName" = "键舞";
"CFBundleDisplayName" = "键舞";
"NSInputMonitoringUsageDescription" = "在其他应用打字时提供敲击反馈，并在本机统计各键的次数。不记录输入文字。";
STRINGS
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleName" = "KeyWoo";
"CFBundleDisplayName" = "KeyWoo";
"NSInputMonitoringUsageDescription" = "Provide typing feedback across apps and count each key locally. Typed text is never recorded.";
STRINGS
swiftc -parse-as-library -module-cache-path "$CLANG_MODULE_CACHE_PATH" scripts/make-icon.swift -o "$ROOT/.build/icon-renderer"
"$ROOT/.build/icon-renderer" "$ROOT/.build/AppIcon.iconset" "$ROOT/Resources/KeyWooIconSource.png"
cp "$ROOT/.build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/.build/AppIcon.iconset/icon_512x512@2x.png" "$APP/Contents/Resources/KeyWooIcon.png"
# Music mode remains internal; omit its recordings and local-model worker.
cp -R "$ROOT/Sources/KeyDance/Resources/KeyboardSounds" "$APP/Contents/Resources/KeyboardSounds"
python3 "$ROOT/scripts/copy-release-docs.py" "$APP/Contents/Resources/Documentation"
python3 "$ROOT/scripts/build-receipt.py" "$ROOT/.build/build-source.json" --verify
cp "$ROOT/.build/build-source.json" "$APP/Contents/Resources/build-source.json"
SIGNING_ARGUMENTS=("$APP")
if [[ -d "$TARGET_APP" ]]; then
  SIGNING_ARGUMENTS+=(--previous "$TARGET_APP")
elif [[ -d "$ROOT/dist/KeyWoo.app" ]]; then
  SIGNING_ARGUMENTS+=(--previous "$ROOT/dist/KeyWoo.app")
fi
if [[ "${KEYWOO_ALLOW_IDENTITY_MIGRATION:-0}" == 1 ]]; then
  SIGNING_ARGUMENTS+=(--allow-identity-migration)
fi
python3 "$ROOT/scripts/sign-app.py" "${SIGNING_ARGUMENTS[@]}"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"

# Both locations are on the same filesystem, so these moves retain the freshly
# signed files' new inodes. Keep the previous complete bundle for recovery.
BACKUP_ROOT=""
if [[ -e "$TARGET_APP" ]]; then
  BACKUP_ROOT="$(mktemp -d "$OUTPUT_DIR/KeyWoo-backup.XXXXXX")"
  mv "$TARGET_APP" "$BACKUP_ROOT/KeyWoo.app.backup"
fi
if ! mv "$APP" "$TARGET_APP"; then
  echo "Could not install the new app bundle." >&2
  if [[ -n "$BACKUP_ROOT" ]]; then
    if mv "$BACKUP_ROOT/KeyWoo.app.backup" "$TARGET_APP"; then
      rmdir "$BACKUP_ROOT"
      echo "Restored the previous app." >&2
    else
      echo "The previous app is preserved at: $BACKUP_ROOT/KeyWoo.app.backup" >&2
    fi
  fi
  exit 1
fi
echo "Built: $TARGET_APP"
if [[ -n "$BACKUP_ROOT" ]]; then
  echo "Previous app preserved: $BACKUP_ROOT/KeyWoo.app.backup"
fi
