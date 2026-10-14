#!/bin/bash

# Exit immediately if any command fails.
set -euo pipefail

# ---------------------------------------------------------------------------
# Single source of truth for build configuration
#
# Every knob below is overridable from the environment, e.g.
#   ARCHS="arm64" SIGNING_IDENTITY="-" ./build.sh
# ---------------------------------------------------------------------------

APP_NAME="Fan Control"
APP_EXECUTABLE="FanControl"
HELPER_EXECUTABLE="smc-helper"
BUNDLE_ID="com.pair.FanControl"

# The marketing version lives here and nowhere else. `hdiutil -volname`, the
# Info.plist, and (via CFBundleShortVersionString) the version badge in
# Views/ContentView.swift all read these, so they can no longer drift apart.
APP_VERSION="${APP_VERSION:-2.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

# Default signing identity. If the certificate is not present in this keychain
# the build falls back to ad-hoc signing instead of failing, so a fresh clone
# can still produce a runnable (locally-signed) app.
DEFAULT_SIGNING_IDENTITY="Developer ID Application: Shahzaib Ali (VJ3BBPZBDU)"
REQUESTED_SIGNING_IDENTITY="${SIGNING_IDENTITY:-$DEFAULT_SIGNING_IDENTITY}"

# Opt-in notarization. Set NOTARY_PROFILE to the name of a `notarytool`
# store-credentials profile to submit + staple. Unset by default so local and
# offline builds never touch the network or require an Apple ID.
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# Opt-in setuid bit on the helper. The helper needs root to talk to the SMC.
#
# It stays opt-in, and it is *not* a substitute for the app's authorization step:
# the bit does not survive the trip to /Applications. Copying the app bundle
# loses the setuid bit and the root ownership along with it, so a setuid build
# only ever helps for someone running the app from this build directory. On any
# real install — DMG drag-and-drop, ZIP, notarized artifact — the user must
# press "Authorize & Enable Fan Adjustments", which runs
# `chown root:wheel && chmod 4755` through AppleScript. That runtime step is the
# one that actually matters, and it is the reason SETUID_HELPER is not flipped on
# by default: a build that silently pre-set the bit would advertise a security
# posture that installation throws away, and would invite anyone reading the
# artifact to believe the helper is already installed correctly when it is not.
SETUID_HELPER="${SETUID_HELPER:-0}"

APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

BUILD_DIR="${BUILD_DIR:-.build}"
PRODUCTS_DIR="$BUILD_DIR/products"
MODULE_CACHE_DIR="${MODULE_CACHE_DIR:-$BUILD_DIR/module-cache}"
ICONSET_DIR="${ICONSET_DIR:-$BUILD_DIR/AppIcon.iconset}"
ENTITLEMENTS_PLIST="$BUILD_DIR/entitlements.plist"

MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-13.0}"
ARCHS="${ARCHS:-arm64 x86_64}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

# `-swift-version 5` pins the language mode so the build does not change
# behaviour when a future toolchain defaults to Swift 6 concurrency checking.
SWIFT_FLAGS=(
    -swift-version 5
    -O
    -whole-module-optimization
)

# The helper deliberately links SMC only — it must NOT link the app-side control
# law, which has no business inside a root-privileged process.
HELPER_SOURCES=(
    Core/SMC.swift
    Helper/main.swift
)

# The app links everything under Core/ (including any pure-logic files such as
# FanControlLaw.swift, which is app-side only).
APP_SOURCES=(
    Core/*.swift
    Models/*.swift
    ViewModels/*.swift
    Views/*.swift
    App/FanControlApp.swift
)

export MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"

# Fail early and loudly rather than passing an unexpanded glob to swiftc, which
# would surface as a confusing "no such file" error much later.
require_swift_sources() {
    local directory="$1"
    local matches=()

    # `nullglob` so a directory with no Swift files yields an empty array rather
    # than the literal (unmatched) pattern.
    shopt -s nullglob
    matches=("$directory"/*.swift)
    shopt -u nullglob

    if [ "${#matches[@]}" -eq 0 ]; then
        echo "Error: no Swift sources found in '$directory'." >&2
        exit 1
    fi
}

require_swift_sources Core
require_swift_sources Models
require_swift_sources ViewModels
require_swift_sources Views
require_swift_sources App

create_universal_binary() {
    local output="$1"
    shift

    if [ "$#" -eq 1 ]; then
        cp "$1" "$output"
    else
        lipo -create "$@" -output "$output"
    fi

    chmod +x "$output"
}

# Resolve the signing identity to something this machine can actually use.
resolve_signing_identity() {
    local requested="$1"

    case "$requested" in
        -|adhoc|ADHOC|"")
            echo "-"
            return
            ;;
    esac

    if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$requested"; then
        echo "$requested"
    else
        echo "-"
    fi
}

SIGNING_IDENTITY="$(resolve_signing_identity "$REQUESTED_SIGNING_IDENTITY")"
SIGNING_WAS_EXPLICIT_ADHOC=false
case "$REQUESTED_SIGNING_IDENTITY" in
    -|adhoc|ADHOC|"") SIGNING_WAS_EXPLICIT_ADHOC=true ;;
esac

echo "=== Building Fan Control App Bundle ==="
echo "Version: $APP_VERSION (build $BUILD_NUMBER)"
echo "Deployment target: macOS $MACOS_DEPLOYMENT_TARGET"
echo "Architectures: $ARCHS"
if [ "$SIGNING_IDENTITY" = "-" ]; then
    if [ "$SIGNING_WAS_EXPLICIT_ADHOC" = true ]; then
        echo "Signing: ad-hoc (requested via SIGNING_IDENTITY)"
    else
        echo "Signing: ad-hoc — no usable certificate found for '$REQUESTED_SIGNING_IDENTITY'." >&2
        echo "         Build is NOT distributable; set SIGNING_IDENTITY or install the certificate." >&2
    fi
else
    echo "Signing: $SIGNING_IDENTITY"
fi

rm -rf "$APP_DIR" "$PRODUCTS_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$PRODUCTS_DIR" "$MODULE_CACHE_DIR"

app_slices=()
helper_slices=()

for arch in $ARCHS; do
    target="${arch}-apple-macosx${MACOS_DEPLOYMENT_TARGET}"
    arch_dir="$PRODUCTS_DIR/$arch"
    helper_output="$arch_dir/$HELPER_EXECUTABLE"
    app_output="$arch_dir/$APP_EXECUTABLE"

    mkdir -p "$arch_dir"

    echo "Compiling $HELPER_EXECUTABLE for $arch (-O -wmo)..."
    swiftc \
        "${SWIFT_FLAGS[@]}" \
        -target "$target" \
        -sdk "$SDK_PATH" \
        -o "$helper_output" \
        "${HELPER_SOURCES[@]}"

    echo "Compiling $APP_EXECUTABLE for $arch (-O -wmo)..."
    swiftc \
        "${SWIFT_FLAGS[@]}" \
        -parse-as-library \
        -target "$target" \
        -sdk "$SDK_PATH" \
        -o "$app_output" \
        -framework Cocoa \
        -framework SwiftUI \
        -framework IOKit \
        "${APP_SOURCES[@]}"

    helper_slices+=("$helper_output")
    app_slices+=("$app_output")
done

echo "Creating app bundle binaries..."
create_universal_binary "$MACOS_DIR/$HELPER_EXECUTABLE" "${helper_slices[@]}"
create_universal_binary "$MACOS_DIR/$APP_EXECUTABLE" "${app_slices[@]}"

echo "Writing Info.plist..."
cat <<EOF > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_EXECUTABLE</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>fr</string>
        <string>de</string>
        <string>es</string>
        <string>zh-Hans</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>$MACOS_DEPLOYMENT_TARGET</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

# A macOS .icns must be compiled from a correctly sized .iconset. Copying a bare
# AppIcon.png into Resources does NOT give the app an icon: the Finder and Dock
# read CFBundleIconFile as an .icns and do not fall back to a PNG resource.
echo "Generating application icon (.icns)..."
if [ -f "app_icon.png" ]; then
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"

    # name:edge size
    while read -r icon_name icon_size; do
        [ -n "$icon_name" ] || continue
        sips -s format png -z "$icon_size" "$icon_size" "app_icon.png" \
            --out "$ICONSET_DIR/$icon_name" >/dev/null
    done <<'ICON_SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
ICON_SIZES

    cat > "$ICONSET_DIR/Contents.json" <<'ICONSET_JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
ICONSET_JSON

    rm -f "$RESOURCES_DIR/AppIcon.icns"
    if iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns" 2>/dev/null; then
        echo "AppIcon.icns generated ($(du -h "$RESOURCES_DIR/AppIcon.icns" | cut -f1))."
    else
        rm -f "$RESOURCES_DIR/AppIcon.icns"
        echo "Warning: iconutil failed; the app will use the generic icon." >&2
    fi
    rm -rf "$ICONSET_DIR"
else
    echo "Warning: app_icon.png not found; the app will use the generic icon." >&2
fi

if [ -d "Localization" ]; then
    echo "Copying localizations..."
    for localization_dir in Localization/*.lproj; do
        [ -d "$localization_dir" ] || continue
        cp -R "$localization_dir" "$RESOURCES_DIR/"
    done
fi

echo "$APP_EXECUTABLE architectures: $(lipo -archs "$MACOS_DIR/$APP_EXECUTABLE")"
echo "$HELPER_EXECUTABLE architectures: $(lipo -archs "$MACOS_DIR/$HELPER_EXECUTABLE")"
echo "$APP_EXECUTABLE deployment targets:"
vtool -show-build "$MACOS_DIR/$APP_EXECUTABLE" | grep "minos"
echo "$HELPER_EXECUTABLE deployment targets:"
vtool -show-build "$MACOS_DIR/$HELPER_EXECUTABLE" | grep "minos"

# The app is intentionally NOT sandboxed: it drives fans through SMC reads and
# writes that only a privileged process can perform, and it launches a setuid
# helper from inside its own bundle. So there is no
# com.apple.security.app-sandbox entitlement here — claiming one would be a lie
# the OS would honour by breaking the app.
#
# What this file does assert is that the shipped build is not debuggable:
# get-task-allow is false, so lldb cannot attach to a distributed copy even
# though the binary is signed with the hardened runtime.
echo "Writing entitlements..."
cat > "$ENTITLEMENTS_PLIST" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.get-task-allow</key>
    <false/>
</dict>
</plist>
ENTITLEMENTS

# 7. Codesign app bundle and binaries.
#
# `--options runtime` (hardened runtime) is required on both binaries and is the
# reason a DYLD_* environment variable cannot be used to hijack the setuid
# helper. It is kept on the ad-hoc path too so local builds exercise the same
# code-signing posture as a distributed build.
echo "Codesigning app and binaries..."
codesign --force --sign "$SIGNING_IDENTITY" --options runtime "$MACOS_DIR/$HELPER_EXECUTABLE"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --entitlements "$ENTITLEMENTS_PLIST" "$MACOS_DIR/$APP_EXECUTABLE"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --entitlements "$ENTITLEMENTS_PLIST" "$APP_DIR"

if [ "$SETUID_HELPER" = "1" ]; then
    # `4755`: setuid root, executable by the logged-in user.
    #
    # The helper must be executable by the user because the app spawns it
    # directly with `Process` — it never runs it through `sudo`. A restrictive
    # mode (`4700`, or `4750` unless the user is in group `wheel`) makes the
    # helper unexecutable, `Process.run()` fails, and every thermal poll is
    # lost: the app sits on "Reading SMC registers..." indefinitely while the
    # helper is present and perfectly correct.
    #
    # Setuid root + world-executable is a real trade-off this design cannot
    # remove: any local user can drive the fans through the helper. It is
    # bounded by the helper's minimal `get`/`set`/`reset` surface and by
    # hardened runtime + library validation blocking DYLD_* injection. Closing
    # it properly needs an XPC privileged helper (SMJobBless) that authenticates
    # the caller.
    echo "Applying setuid bit to $HELPER_EXECUTABLE (4755: setuid root, executable by the user)..."
    chmod 4755 "$MACOS_DIR/$HELPER_EXECUTABLE"

    # Read the result back rather than trusting the chmod: an ACL, a read-only
    # volume, or a non-root build can all make it a silent no-op or a partial
    # success. `FanViewModel.helperAuthorizationStatus` requires uid 0 + setuid +
    # owner-execute + user-execute + not-writable-by-others, so this checks the
    # same predicate and complains here instead of shipping something the app
    # will reject.
    helper_path="$MACOS_DIR/$HELPER_EXECUTABLE"
    helper_uid="$(stat -f '%u' "$helper_path")"
    helper_mode="$(stat -f '%Lp' "$helper_path")"
    helper_setuid="no"
    [ -u "$helper_path" ] && helper_setuid="yes"
    echo "$HELPER_EXECUTABLE: mode $helper_mode, owner uid $helper_uid, setuid $helper_setuid"

    if [ "$helper_uid" != "0" ]; then
        {
            echo "Warning: setuid is inert without root ownership — $HELPER_EXECUTABLE is owned by uid $helper_uid, not 0."
            echo "         Re-run this build as root, or use the app's \"Authorize & Enable Fan Adjustments\""
            echo "         button, which runs 'chown root:wheel && chmod 4755' for you."
            echo "         Until one of those happens the app reports the helper as unauthorized."
        } >&2
    elif [ "$helper_setuid" != "yes" ] \
        || [ $((8#$helper_mode & 0100)) -eq 0 ] \
        || [ $((8#$helper_mode & 0077)) -ne 0 ]; then
        echo "Warning: expected a 4755 root-owned setuid helper, got $helper_mode (setuid $helper_setuid)." >&2
        echo "         The app will not treat this artifact as authorized." >&2
    fi
fi

echo "Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

# Notarization is opt-in. A hardened-runtime + setuid-root binary must be
# notarized to run on any other Mac, but local development machines and offline
# CI have no business uploading artifacts, so this stays behind NOTARY_PROFILE.
#
# The app bundle is notarized and stapled BEFORE packaging so that both the DMG
# and the ZIP fallback carry a stapled ticket on the app itself.
notarize_and_staple() {
    local subject="$1"

    echo "Notarizing $subject..."
    local archive="$BUILD_DIR/notary-submit.zip"
    rm -f "$archive"

    if [ -d "$subject" ]; then
        ditto -c -k --sequesterRsrc --keepParent "$subject" "$archive"
    else
        cp "$subject" "$archive"
    fi

    if ! xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" --wait; then
        echo "Error: notarization was rejected for $subject." >&2
        echo "Run 'xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE' for details." >&2
        exit 1
    fi
    rm -f "$archive"

    xcrun stapler staple "$subject"
    xcrun stapler validate "$subject"
}

if [ -n "$NOTARY_PROFILE" ]; then
    notarize_and_staple "$APP_DIR"
else
    echo "Notarization: skipped (set NOTARY_PROFILE to enable)."
fi

# 8. Create a drag-and-drop DMG when possible. Some managed, sandboxed, or
# headless environments cannot provide the device service required by hdiutil;
# in that case, preserve the signed app in a Finder-installable ZIP instead.
echo "Packaging to DMG..."
rm -f "Fan Control.dmg"
rm -f "Fan Control.zip"
rm -rf dist
mkdir -p dist
cp -R "$APP_DIR" dist/
# Add a symbolic link to /Applications for easy drag-and-drop installation
ln -s /Applications dist/Applications

if hdiutil create -volname "$APP_NAME v$APP_VERSION" -srcfolder dist -ov -format UDZO "Fan Control.dmg"; then
    rm -rf dist
    echo "Codesigning DMG..."
    codesign --force --sign "$SIGNING_IDENTITY" "Fan Control.dmg"

    if [ -n "$NOTARY_PROFILE" ]; then
        notarize_and_staple "Fan Control.dmg"
    fi

    echo "=== Build and Packaging Complete: 'Fan Control.dmg' created successfully ==="
else
    rm -f "Fan Control.dmg"
    rm -rf dist

    echo "Warning: DMG packaging failed; creating a ZIP fallback..."
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "Fan Control.zip"

    if [ -n "$NOTARY_PROFILE" ]; then
        notarize_and_staple "Fan Control.zip"
    fi

    echo "=== Build and Packaging Complete: 'Fan Control.zip' created successfully ==="
fi