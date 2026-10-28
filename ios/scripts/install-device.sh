#!/bin/sh
set -eu
EMBRYO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$EMBRYO_ROOT"
if [ "$#" -ne 1 ]; then
    echo 'Usage: scripts/install-device.sh DEVICE_ID' >&2
    echo 'Find a connected, trusted device with: xcrun devicectl list devices' >&2
    exit 2
fi
EMBRYO_DEVICE_ID=$1
python3 scripts/generate-project.py
xcodebuild -project Embryo.xcodeproj -scheme Embryo -configuration Debug \
    -destination "platform=iOS,id=$EMBRYO_DEVICE_ID" -derivedDataPath Build/DeviceSigned \
    -allowProvisioningUpdates build
xcrun devicectl device install app --device "$EMBRYO_DEVICE_ID" \
    "$EMBRYO_ROOT/Build/DeviceSigned/Build/Products/Debug-iphoneos/Embryo.app"
xcrun devicectl device process launch --device "$EMBRYO_DEVICE_ID" dev.evergreen.embryo
