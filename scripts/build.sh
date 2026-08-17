#!/usr/bin/env bash
# Build the dedicated Storage Rescue app for iphoneos and package the resulting
# .app into a versioned IPA under build/. The public identity/version comes
# from StorageRescue.xcconfig and is intentionally independent from upstream
# Cyanide target defaults. The internal Xcode product remains Cyanide.app
# because the inherited target has linker paths tied to that binary name.
#
# Run as: ./scripts/build.sh
# Override defaults with env vars:
#   SCHEME, CONFIG (Debug|Release|VPhone Debug), SDK (iphoneos|iphonesimulator)
#
# Code signing is disabled — the IPA ships unsigned for compatible sideloading
# workflows, which apply their own signing.

set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="${SCHEME:-Cyanide}"
if [ "$SCHEME" = "CyanideVPhone" ]; then
    CONFIG="${CONFIG:-VPhone Debug}"
    if [ "$CONFIG" != "VPhone Debug" ]; then
        echo "error: CyanideVPhone must use CONFIG='VPhone Debug'" >&2
        exit 1
    fi
else
    CONFIG="${CONFIG:-Debug}"
    if [ "$CONFIG" = "VPhone Debug" ]; then
        echo "error: CONFIG='VPhone Debug' is only for SCHEME=CyanideVPhone" >&2
        exit 1
    fi
fi
SDK="${SDK:-iphoneos}"
PROJECT="Cyanide.xcodeproj"
DERIVED="$PWD/build/DerivedData"
PRODUCT_DIR="$DERIVED/Build/Products/${CONFIG}-${SDK}"
XCODEBUILD_EXTRA=()
XCCONFIG_ARGS=()

if [ "$SDK" = "iphonesimulator" ]; then
    XCODEBUILD_EXTRA=(ARCHS=arm64 ONLY_ACTIVE_ARCH=YES)
fi

if [ "$SCHEME" = "CyanideVPhone" ]; then
    APP_NAME="Cyanide.app"
    IPA_PREFIX="CyanideVPhone"
else
    APP_NAME="Cyanide.app"
    IPA_PREFIX="Storage-Rescue"
    XCCONFIG_ARGS=(-xcconfig "$PWD/StorageRescue.xcconfig")
fi

IPA_LATEST="$PWD/build/${IPA_PREFIX}.ipa"
mkdir -p build

echo "==> xcodebuild ($SCHEME / $CONFIG / $SDK)"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -sdk "$SDK" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    "${XCCONFIG_ARGS[@]}" \
    CODE_SIGNING_ALLOWED=NO \
    ${XCODEBUILD_EXTRA[@]+"${XCODEBUILD_EXTRA[@]}"} \
    build \
    | xcbeautify --quiet 2>/dev/null \
    || xcodebuild \
         -project "$PROJECT" \
         -scheme "$SCHEME" \
         -sdk "$SDK" \
         -configuration "$CONFIG" \
         -derivedDataPath "$DERIVED" \
         "${XCCONFIG_ARGS[@]}" \
         CODE_SIGNING_ALLOWED=NO \
         ${XCODEBUILD_EXTRA[@]+"${XCODEBUILD_EXTRA[@]}"} \
         build

APP_PATH="$PRODUCT_DIR/$APP_NAME"
if [ ! -d "$APP_PATH" ]; then
    echo "error: $APP_PATH not found after build" >&2
    echo "products in $PRODUCT_DIR:" >&2
    find "$PRODUCT_DIR" -maxdepth 1 -type d -name '*.app' -print >&2 || true
    exit 1
fi

normalize_storage_rescue_plist() {
    local plist="$1"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Storage Rescue" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName StorageRescue" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier io.github.boierito.storagerescue" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.1.0" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion 110" "$plist"
}

# Keep the intermediate product coherent for local inspection. The same
# normalization is repeated on the staged payload below because the IPA payload
# is the actual installation source of truth.
if [ "$SCHEME" != "CyanideVPhone" ]; then
    normalize_storage_rescue_plist "$APP_PATH/Info.plist"
fi

if [ "$SDK" = "iphonesimulator" ]; then
    echo "==> simulator app $APP_PATH"
    exit 0
fi

if [ "$SCHEME" = "CyanideVPhone" ]; then
    VPHONE_BRIDGE_SRC="$PWD/vphone-assets/vphone_springboard_bridge.dylib"
    VPHONE_BRIDGE_SOURCE="$PWD/vphone-assets/vphone_springboard_bridge.m"
    VPHONE_BRIDGE_DST="$APP_PATH/vphone_springboard_bridge.dylib"
    if [ -f "$VPHONE_BRIDGE_SOURCE" ]; then
        echo "==> building vphone SpringBoard bridge"
        VPHONE_BRIDGE_BUILD="$PWD/build/vphone-bridge"
        VPHONE_BRIDGE_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
        mkdir -p "$VPHONE_BRIDGE_BUILD"
        xcrun --sdk iphoneos clang -arch arm64 \
            -isysroot "$VPHONE_BRIDGE_SDK" \
            -miphoneos-version-min=15.0 \
            -dynamiclib \
            "$VPHONE_BRIDGE_SOURCE" \
            -framework Foundation -framework CoreFoundation -lobjc \
            -install_name @rpath/vphone_springboard_bridge.dylib \
            -o "$VPHONE_BRIDGE_BUILD/vphone_springboard_bridge.arm64.dylib"
        xcrun --sdk iphoneos clang -arch arm64e \
            -isysroot "$VPHONE_BRIDGE_SDK" \
            -miphoneos-version-min=15.0 \
            -dynamiclib \
            "$VPHONE_BRIDGE_SOURCE" \
            -framework Foundation -framework CoreFoundation -lobjc \
            -install_name @rpath/vphone_springboard_bridge.dylib \
            -o "$VPHONE_BRIDGE_BUILD/vphone_springboard_bridge.arm64e.dylib"
        lipo -create \
            "$VPHONE_BRIDGE_BUILD/vphone_springboard_bridge.arm64.dylib" \
            "$VPHONE_BRIDGE_BUILD/vphone_springboard_bridge.arm64e.dylib" \
            -output "$VPHONE_BRIDGE_SRC"
    fi
    if [ ! -f "$VPHONE_BRIDGE_SRC" ]; then
        echo "error: missing vphone bridge dylib: $VPHONE_BRIDGE_SRC" >&2
        exit 1
    fi
    echo "==> bundling vphone SpringBoard bridge"
    ditto "$VPHONE_BRIDGE_SRC" "$VPHONE_BRIDGE_DST"
    chmod 0755 "$VPHONE_BRIDGE_DST"
    ldid -S "$VPHONE_BRIDGE_DST"
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Info.plist" 2>/dev/null || true)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Info.plist" 2>/dev/null || true)
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Info.plist" 2>/dev/null || true)
if [ -z "$VERSION" ] || [ -z "$BUILD" ] || [ -z "$BUNDLE_ID" ]; then
    echo "error: could not read Storage Rescue identity from $APP_PATH/Info.plist" >&2
    exit 1
fi

echo "==> identity $BUNDLE_ID · version $VERSION ($BUILD)"

IPA_OUT="$PWD/build/${IPA_PREFIX}-${VERSION}.ipa"
IPA_BASENAME="$(basename "$IPA_OUT")"
LATEST_BASENAME="$(basename "$IPA_LATEST")"

echo "==> packaging $IPA_OUT"
STAGE="$(mktemp -d -t storage-rescue-ipa)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP_PATH" "$STAGE/Payload/"

if [ "$SCHEME" != "CyanideVPhone" ]; then
    FINAL_PLIST="$STAGE/Payload/$APP_NAME/Info.plist"
    normalize_storage_rescue_plist "$FINAL_PLIST"
    echo "==> final payload identity"
    /usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$FINAL_PLIST"
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$FINAL_PLIST"
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$FINAL_PLIST"
    /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$FINAL_PLIST"
fi

rm -f "$IPA_OUT"
( cd "$STAGE" && zip -qry "$IPA_OUT" Payload )

rm -f "$IPA_LATEST"
( cd "$PWD/build" && ln -s "$IPA_BASENAME" "$LATEST_BASENAME" )

# Compatibility link for older local scripts while the repository transitions
# away from the inherited Cyanide product name.
if [ "$SCHEME" != "CyanideVPhone" ]; then
    rm -f "$PWD/build/Cyanide.ipa"
    ( cd "$PWD/build" && ln -s "$IPA_BASENAME" Cyanide.ipa )
fi

SIZE=$(du -h "$IPA_OUT" | cut -f1)
echo "==> wrote $IPA_OUT ($SIZE)"
echo "==> symlink $IPA_LATEST -> $IPA_BASENAME"

if [ "$SCHEME" = "CyanideVPhone" ]; then
    ARM64_IPA_OUT="$PWD/build/CyanideVPhone-vphone-arm64.ipa"
    ARM64_STAGE="$(mktemp -d -t cyanide-vphone-arm64)"
    trap 'rm -rf "$STAGE" "${ARM64_STAGE:-}"' EXIT
    mkdir -p "$ARM64_STAGE/Payload"
    ditto "$APP_PATH" "$ARM64_STAGE/Payload/Cyanide.app"
    lipo "$ARM64_STAGE/Payload/Cyanide.app/Cyanide" -thin arm64 \
        -output "$ARM64_STAGE/Payload/Cyanide.app/Cyanide.arm64"
    mv "$ARM64_STAGE/Payload/Cyanide.app/Cyanide.arm64" \
        "$ARM64_STAGE/Payload/Cyanide.app/Cyanide"
    chmod +x "$ARM64_STAGE/Payload/Cyanide.app/Cyanide"
    ldid -S"$PWD/scripts/vphone_app.entitlements" \
        "$ARM64_STAGE/Payload/Cyanide.app/Cyanide"
    rm -f "$ARM64_IPA_OUT"
    ( cd "$ARM64_STAGE" && zip -qry "$ARM64_IPA_OUT" Payload )
    ARM64_SIZE=$(du -h "$ARM64_IPA_OUT" | cut -f1)
    echo "==> wrote $ARM64_IPA_OUT ($ARM64_SIZE)"
fi
