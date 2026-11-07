#!/bin/bash
# Archive, export and upload Duo Desk build N to TestFlight.
# Usage: Scripts/testflight/release.sh N   (App Store Connect app 6832027461)
set -euo pipefail
N=${1:?build number}
APP=${DUO_DESK_APP_ID:-6832027461}
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-27.2.0.app/Contents/Developer}
OUT=build-testflight; mkdir -p "$OUT"
/usr/bin/python3 - "$N" <<'PY'
import re, sys
p = "project.yml"; s = open(p).read()
s = re.sub(r"(PRODUCT_BUNDLE_IDENTIFIER: com\.macmax\.duodesk(?:\n.*?)*?CURRENT_PROJECT_VERSION: )'\d+'", r"\g<1>'%s'" % sys.argv[1], s, count=1)
open(p, "w").write(s)
PY
xcodegen generate -q
xcodebuild -project DuoWorkspace.xcodeproj -scheme DuoWorkspace -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$OUT/DerivedData" \
  -archivePath "$OUT/DuoDesk-$N.xcarchive" archive -quiet > "$OUT/archive-$N.log" 2>&1
PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/xcodebuild -exportArchive -archivePath "$OUT/DuoDesk-$N.xcarchive" \
  -exportPath "$OUT/export-$N" -exportOptionsPlist Scripts/testflight/ExportOptions.plist > "$OUT/export-$N.log" 2>&1
codesign --verify --deep --strict "$OUT/DuoDesk-$N.xcarchive/Products/Applications/DuoWorkspace.app"
asc --profile Gather builds upload --app "$APP" --ipa "$OUT/export-$N/DuoWorkspace.ipa" --output json > "$OUT/upload-$N.json"
cat "$OUT/upload-$N.json"
