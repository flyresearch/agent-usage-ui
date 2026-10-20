#!/bin/sh
# Assemble Agent Usage with the original Syrtis runtime plus optional fleet scope.
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
app=${AGENT_USAGE_APP_DIR:-'.build/fleet/Agent Usage.app'}
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
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleIconFile</key><string>agent-usage</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Agent Usage connects to configured local agent services to display account quota and usage.</string>
<key>AgentUsageOffline</key><true/>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>zh-Hant</string></array>
</dict></plist>
PLIST
revision=$(git rev-parse --short=12 HEAD)
if ! git diff --quiet || ! git diff --cached --quiet; then revision="$revision-dirty"; fi
/usr/libexec/PlistBuddy -c "Add :AgentUsageRevision string $revision" "$app/Contents/Info.plist"
python3 - "$app/Contents/Info.plist" <<'PYCONFIG'
import base64, os, plistlib, sys, urllib.parse
feed=os.environ.get('AGENT_USAGE_FEED_URL')
key=os.environ.get('AGENT_USAGE_UPDATE_PUBLIC_KEY')
if feed or key:
    parsed=urllib.parse.urlparse(feed or '')
    try: valid_key=len(base64.b64decode(key or '',validate=True))==32
    except ValueError: valid_key=False
    if not (parsed.scheme=='https' and not parsed.username and not parsed.password and not parsed.query and not parsed.fragment and parsed.hostname in ('github.com','raw.githubusercontent.com') and parsed.path.split('/')[1:3]==['flyresearch','agent-usage-ui'] and valid_key):
        raise SystemExit('invalid_independent_update_configuration')
    with open(sys.argv[1],'rb') as f: info=plistlib.load(f)
    info['SUFeedURL']=feed;info['SUPublicEDKey']=key
    with open(sys.argv[1],'wb') as f: plistlib.dump(info,f)
PYCONFIG
# No upstream update feed is embedded. A separate signed feed is required.
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Agent Usage bundle ready at $app (local ad-hoc signature)."
