#!/bin/bash
# Assert the invariants that are easy to silently regress in the packaged app:
# signature validity, universal architecture, deployment target, optimization,
# a real app icon, and localizations copied into the bundle.
#
# Usage: .github/scripts/verify-build.sh [app-bundle] [build-script]
# Honours MACOS_DEPLOYMENT_TARGET and ARCHS so CI and build.sh agree on one
# source of truth.
#
# Exit: 0 = all checks passed, 1 = at least one check failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

APP_DIR="${1:-$REPO_ROOT/Fan Control.app}"
BUILD_SCRIPT="${2:-$REPO_ROOT/build.sh}"
APP_BIN="$APP_DIR/Contents/MacOS/FanControl"
HELPER_BIN="$APP_DIR/Contents/MacOS/smc-helper"

EXPECTED_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-13.0}"
REQUIRED_ARCHS="${ARCHS:-arm64 x86_64}"

# Deliberately loose. This only catches an empty or stubbed binary; the real
# optimization guard is the build.sh flag check below.
MIN_APP_BINARY_BYTES="${MIN_APP_BINARY_BYTES:-1000000}"

failures=0
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }
pass() { printf 'ok    %s\n' "$*"; }

check_codesign() {
    local output rc=0
    output="$(codesign --verify --deep --strict "$APP_DIR" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "codesign --verify --deep --strict"
    else
        fail "codesign --verify --deep --strict failed (exit $rc)"
        printf '%s\n' "$output" | sed 's/^/        /' >&2
    fi
}

check_universal() {
    local binary="$1" label="$2" archs missing="" arch
    if [ ! -f "$binary" ]; then
        fail "$label: binary missing ($binary)"
        return
    fi
    archs="$(lipo -archs "$binary")"
    for arch in $REQUIRED_ARCHS; do
        case " $archs " in
            *" $arch "*) ;;
            *) missing="$missing $arch" ;;
        esac
    done
    if [ -n "$missing" ]; then
        fail "$label: not universal, missing:$missing (lipo reports: $archs)"
    else
        pass "$label: universal ($archs)"
    fi
}

check_minos() {
    local binary="$1" label="$2" output regex
    if [ ! -f "$binary" ]; then
        fail "$label: binary missing ($binary)"
        return
    fi
    # The value is substituted into a regex, so pin the '.' that macOS
    # reports as e.g. "minos 13.00".
    regex="minos[[:space:]]+${EXPECTED_DEPLOYMENT_TARGET//./\\.}"
    output="$(vtool -show-build "$binary" 2>/dev/null || true)"
    if printf '%s\n' "$output" | grep -Eq "$regex"; then
        pass "$label: minos $EXPECTED_DEPLOYMENT_TARGET"
    else
        fail "$label: expected minos $EXPECTED_DEPLOYMENT_TARGET, vtool reported:"
        printf '%s\n' "$output" | sed 's/^/        /' >&2
    fi
}

check_optimized() {
    local flags
    if [ ! -f "$BUILD_SCRIPT" ]; then
        fail "build script missing ($BUILD_SCRIPT)"
        return
    fi
    # Matches -O / -Osize / -Ounchecked / -Owholemodule but deliberately not
    # -Onone: the trailing character class forbids a word character, so the
    # next 'n' in "-Onone" cannot satisfy it.
    if grep -Eq -- '-O(size|unchecked|wholemodule)?([^[:alnum:]]|$)' "$BUILD_SCRIPT"; then
        flags="$(grep -Eo -- '-O(size|unchecked|wholemodule)?([^[:alnum:]]|$)' "$BUILD_SCRIPT" \
            | LC_ALL=C sort -u | tr '\n' ' ')"
        pass "build.sh passes an optimization flag: $flags"
    else
        fail "build.sh passes no optimization flag; swiftc defaults to -Onone"
    fi
}

check_binary_size() {
    local binary="$1" label="$2" min="$3" size
    if [ ! -f "$binary" ]; then
        fail "$label: binary missing ($binary)"
        return
    fi
    size="$(wc -c < "$binary" | tr -d ' \t')"
    if [ "$size" -ge "$min" ]; then
        pass "$label: $size bytes (>= $min)"
    else
        fail "$label: only $size bytes (< $min); binary looks truncated or stubbed"
    fi
}

check_icon() {
    local icon="$APP_DIR/Contents/Resources/AppIcon.icns" size
    if [ ! -f "$icon" ]; then
        fail "no AppIcon.icns in Contents/Resources; the app would ship a generic icon"
        return
    fi
    size="$(wc -c < "$icon" | tr -d ' \t')"
    if [ "$size" -lt 1024 ]; then
        fail "AppIcon.icns is only $size bytes; that is not a real icon"
        return
    fi
    pass "AppIcon.icns present ($size bytes)"
}

check_bundle_localizations() {
    local resources="$APP_DIR/Contents/Resources" lang found=0 missing=""
    for dir in "$REPO_ROOT"/Localization/*.lproj; do
        [ -d "$dir" ] || continue
        lang="$(basename "$dir")"
        if [ -f "$resources/$lang/Localizable.strings" ]; then
            found=$((found + 1))
        else
            missing="$missing $lang"
        fi
    done
    if [ "$found" -eq 0 ]; then
        fail "no .lproj folders were copied into Contents/Resources"
    elif [ -n "$missing" ]; then
        fail "localizations missing from the bundle:$missing"
    else
        pass "all $found localizations present in Contents/Resources"
    fi
}

check_info_plist() {
    local value
    if [ ! -f "$APP_DIR/Contents/Info.plist" ]; then
        fail "no Info.plist in the app bundle"
        return
    fi
    value="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
        "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$value" = "$EXPECTED_DEPLOYMENT_TARGET" ]; then
        pass "Info.plist LSMinimumSystemVersion = $EXPECTED_DEPLOYMENT_TARGET"
    else
        fail "Info.plist LSMinimumSystemVersion = '${value}' (expected $EXPECTED_DEPLOYMENT_TARGET)"
    fi
}

printf '== Verifying %s ==\n\n' "$APP_DIR"

check_codesign
check_universal "$APP_BIN" "FanControl"
check_universal "$HELPER_BIN" "smc-helper"
check_minos "$APP_BIN" "FanControl"
check_minos "$HELPER_BIN" "smc-helper"
check_optimized
check_binary_size "$APP_BIN" "FanControl binary" "$MIN_APP_BINARY_BYTES"
check_icon
check_bundle_localizations
check_info_plist

printf '\n'
if [ "$failures" -ne 0 ]; then
    printf '%s check(s) failed.\n' "$failures" >&2
    exit 1
fi
printf 'All build checks passed.\n'
