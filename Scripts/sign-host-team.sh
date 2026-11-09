#!/bin/bash
# Sign a built Duo Workspace Host with the team's Developer ID so every rebuild keeps
# the same identity (team 6W6FT9SXBU). The keychain item and Screen Recording /
# Accessibility grants then survive rebuilds instead of prompting each time.
set -euo pipefail
app="${1:-/tmp/duo-native/full/mac/Build/Products/Debug/DuoWorkspaceHost.app}"
codesign --force --deep --timestamp=none --sign "Developer ID Application: Akshay Asok (6W6FT9SXBU)" "$app"
codesign --verify --strict "$app"
codesign -d -r- "$app" 2>&1 | tail -1
