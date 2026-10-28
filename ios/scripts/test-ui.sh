#!/bin/sh
set -eu
EMBRYO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$EMBRYO_ROOT"
python3 scripts/generate-project.py
if [ -z "${SIMULATOR_ID:-}" ]; then
    SIMULATOR_ID=$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = [device for group in json.load(sys.stdin)["devices"].values() for device in group
           if device.get("isAvailable") and device["name"].startswith("iPhone")]
devices.sort(key=lambda device: device["state"] != "Booted")
if not devices:
    sys.exit("No available iPhone simulator. Install an iOS runtime in Xcode Settings > Components.")
print(devices[0]["udid"])
')
fi
xcodebuild -project Embryo.xcodeproj -scheme Embryo -configuration Debug \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    -derivedDataPath Build/UITests -only-testing:EmbryoUITests/EmbryoUITests CODE_SIGNING_ALLOWED=NO test
