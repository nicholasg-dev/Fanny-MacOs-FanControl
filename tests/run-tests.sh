#!/bin/bash
# Builds and runs the fan-control unit tests in tests/unit/.
#
# The fan-control law and the history/telemetry stores are plain Swift with no
# UI, helper or window dependency, so they compile on their own against the
# shared models. Exit: 0 = all checks pass.
#
# Usage: tests/run-tests.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fancontrol-unit-tests.XXXXXX")"
trap 'rm -rf "$OUT_DIR"' EXIT

swiftc -swift-version 5 -O \
    -o "$OUT_DIR/unit-tests" \
    "$REPO_ROOT/Core/FanControlLaw.swift" \
    "$REPO_ROOT/Core/Localization.swift" \
    "$REPO_ROOT/Models/FanJSON.swift" \
    "$REPO_ROOT/Models/TempRecord.swift" \
    "$REPO_ROOT/ViewModels/FanStores.swift" \
    "$REPO_ROOT/tests/unit/main.swift"

"$OUT_DIR/unit-tests"
