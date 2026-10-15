#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
    echo 'Usage: bundle.sh PATH_TO_COLLECTOR_BINARY PATH_TO_COLLECTOR_SOURCE' >&2
    exit 1
fi
collector=$1
collector_source=$2
if [ ! -f "$collector_source/LICENSE" ] || [ ! -d "$collector_source/third_party" ]; then
    echo "Collector source license and notices are required" >&2
    exit 1
fi
if [ ! -f "$collector" ] || [ ! -x "$collector" ]; then
    echo 'Collector binary is missing or not executable' >&2
    exit 1
fi
package_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift build --package-path "$package_dir" --product AgentUsage
bin_dir=$(swift build --package-path "$package_dir" --show-bin-path)
app="$package_dir/.build/Agent Usage.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/AgentUsage" "$app/Contents/MacOS/AgentUsage"
cp "$collector" "$app/Contents/MacOS/agent-usage"
cp -R "$bin_dir"/*_UsageCore.bundle "$app/Contents/Resources/"
cp "$package_dir/../LICENSE" "$app/Contents/Resources/LICENSE"
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
<key>CFBundleExecutable</key><string>AgentUsage</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app"
echo 'Local app bundle created under offline-ui/.build (not a signed distribution release).'
