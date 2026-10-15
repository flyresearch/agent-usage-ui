#!/bin/sh
# Assemble the original Syrtis target with the explicit collector/fleet runtime.
set -eu
if [ "$#" -ne 2 ]; then
  echo 'Usage: bundle-fleet.sh COLLECTOR_BINARY COLLECTOR_SOURCE' >&2
  exit 1
fi
collector=$1
collector_source=$2
test -x "$collector"
test -f "$collector_source/LICENSE"
test -d "$collector_source/third_party"
cd "$(dirname "$0")/.."
cargo build --release --locked -p tb_core_ffi
swift build --product Syrtis
bin=$(swift build --show-bin-path)
app='.build/fleet/Agent Usage.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin/Syrtis" "$app/Contents/MacOS/Syrtis"
cp "$collector" "$app/Contents/MacOS/agent-usage"
cp -R "$bin/Syrtis_Syrtis.bundle" "$app/Contents/Resources/"
cp -R Sources/Syrtis/Resources/Localizations/*.lproj "$app/Contents/Resources/"
cp -R "$bin/Sparkle.framework" "$app/Contents/Frameworks/"
cp -R "$bin"/*_UsageCore.bundle "$app/Contents/Resources/"
cp Sources/Syrtis/Resources/agent-usage.icns "$app/Contents/Resources/agent-usage.icns"
cp LICENSE "$app/Contents/Resources/LICENSE"
mkdir -p "$app/Contents/Resources/collector-notices"
cp "$collector_source/LICENSE" "$app/Contents/Resources/collector-notices/LICENSE"
cp -R "$collector_source/third_party/." "$app/Contents/Resources/collector-notices/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.flyresearch.agentusage</string>
<key>CFBundleName</key><string>Agent Usage</string>
<key>CFBundleDisplayName</key><string>Agent Usage</string>
<key>CFBundleExecutable</key><string>Syrtis</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleIconFile</key><string>agent-usage</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>AgentUsageOffline</key><true/>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>zh-Hant</string></array>
</dict></plist>
PLIST
# The original target links Sparkle, but FleetMode never constructs its updater.
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
echo 'Original Syrtis UI fleet bundle ready under .build/fleet (local ad-hoc signature).'
