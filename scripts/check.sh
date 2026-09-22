#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product BridgeChecks
.build/debug/BridgeChecks
