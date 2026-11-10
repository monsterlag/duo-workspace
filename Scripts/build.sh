#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/build-environment.sh
duo_build_root="$DUO_BUILD_ROOT"
duo_host_app="$duo_build_root/mac/Build/Products/Debug/DuoWorkspaceHost.app"
duo_apple_signing="$PWD/.secrets/AppleDevelopment.xcconfig"
duo_host_build_args=(
    -project DuoWorkspace.xcodeproj
    -scheme DuoWorkspaceHost
    -destination 'platform=macOS'
    -derivedDataPath "$duo_build_root/mac"
)
# Without Apple Development signing the host build phase signs with the team
# Developer ID (Scripts/sign-host-team.sh), so there is no local identity to set up.
if [[ -f "$duo_apple_signing" ]]; then
    duo_host_build_args+=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
fi
DUO_BUILD_ROOT="$duo_build_root" Scripts/test-microphone-driver.sh
python3 Scripts/test-microphone-package.py
swift test --scratch-path "$duo_build_root/swift"
xcodebuild "${duo_host_build_args[@]}" build
/usr/bin/codesign --verify --deep --strict "$duo_host_app"
if [[ -n "${DUO_TEST_DESTINATION:-}" ]]; then
    xcodebuild -project DuoWorkspace.xcodeproj -scheme DuoWorkspace -destination "$DUO_TEST_DESTINATION" -derivedDataPath "$duo_build_root/ios" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
else
    xcodebuild -project DuoWorkspace.xcodeproj -scheme DuoWorkspace -destination 'generic/platform=iOS Simulator' -derivedDataPath "$duo_build_root/ios" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
fi
