#!/bin/sh
set -eu
EMBRYO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$EMBRYO_ROOT"
python3 scripts/generate-project.py
EMBRYO_BUILD_KIND=${1:-all}
case "$EMBRYO_BUILD_KIND" in
    simulator|all)
        xcodebuild -project Embryo.xcodeproj -scheme Embryo -configuration Debug \
            -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
            -derivedDataPath Build/Simulator CODE_SIGNING_ALLOWED=NO build
        ;;
    device) ;;
    *) echo 'Usage: scripts/build.sh [simulator|device|all]' >&2; exit 2 ;;
esac
case "$EMBRYO_BUILD_KIND" in
    device|all)
        xcodebuild -project Embryo.xcodeproj -scheme Embryo -configuration Release \
            -sdk iphoneos -destination 'generic/platform=iOS' \
            -derivedDataPath Build/Device CODE_SIGNING_ALLOWED=NO build
        ;;
esac
