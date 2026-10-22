#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
./Scripts/bootstrap-pjsip.sh
swift test
swift build --product SIPProbe
BIN="$(swift build --show-bin-path)"
/usr/bin/python3 Tests/Integration/test_loopback.py "$BIN/SIPProbe"

