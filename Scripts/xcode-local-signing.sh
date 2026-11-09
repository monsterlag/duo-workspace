#!/bin/bash
set -euo pipefail
case "${DUO_LOCAL_SIGNING:-YES}" in
  NO)
    if [[ "${CODE_SIGNING_ALLOWED:-NO}" != YES ]]; then
      echo 'Enable local signing or configure Xcode signing before building the host.' >&2
      exit 1
    fi
    exit 0
    ;;
  YES) ;;
  *) echo 'DUO_LOCAL_SIGNING must be YES or NO.' >&2; exit 1 ;;
esac
cd "$(dirname "$0")/.."
app="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
case "${1:-}" in
  # Team Developer ID signing keeps one identity across rebuilds, so keychain and
  # privacy grants are not asked for again on every build.
  prepare) exit 0 ;;
  sign) exec Scripts/sign-host-team.sh "$app" ;;
  *) echo 'Expected prepare or sign.' >&2; exit 64 ;;
esac
