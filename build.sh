#!/bin/bash
# Builds QuickGPX.app (host app + Quick Look preview & thumbnail extensions)
# without an Xcode project, then installs it to ~/Applications and registers
# the extensions.
#
# Usage:
#   ./build.sh              ad-hoc signed, for this Mac only
#   ./build.sh --release    Developer ID signed + notarized + stapled,
#                           distributable zip written to dist/
set -euo pipefail
cd "$(dirname "$0")"

RELEASE=0
[ "${1:-}" = "--release" ] && RELEASE=1

DEV_ID="Developer ID Application: Nicolas Seriot (VBYRKYS73S)"
NOTARY_PROFILE="notary"

ARCH=$(uname -m)
TARGET="$ARCH-apple-macos12.0"
# Build outside the project folder: building inside Dropbox/CloudStorage races
# the file provider and stamps xattrs that codesign rejects as "detritus".
BUILD="${TMPDIR:-/tmp}/quickgpx-build"
APP="$BUILD/QuickGPX.app"
CONTENTS="$APP/Contents"

rm -rf "$BUILD"
mkdir -p "$BUILD/bin" \
         "$CONTENTS/MacOS" \
         "$CONTENTS/Resources" \
         "$CONTENTS/PlugIns/GPXPreview.appex/Contents/MacOS" \
         "$CONTENTS/PlugIns/GPXThumbnail.appex/Contents/MacOS"

echo "==> Compiling preview extension"
xcrun swiftc -O -target "$TARGET" -parse-as-library -application-extension \
    Sources/Shared/*.swift Sources/Preview/PreviewViewController.swift \
    Sources/Preview/ElevationProfileView.swift \
    -framework AppKit -framework Quartz -framework MapKit \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$BUILD/bin/GPXPreview"

echo "==> Compiling thumbnail extension"
xcrun swiftc -O -target "$TARGET" -parse-as-library -application-extension \
    Sources/Shared/*.swift Sources/Thumbnail/ThumbnailProvider.swift \
    -framework AppKit -framework QuickLookThumbnailing \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$BUILD/bin/GPXThumbnail"

echo "==> Compiling host app"
xcrun swiftc -O -target "$TARGET" \
    Sources/App/main.swift \
    -framework AppKit \
    -o "$BUILD/bin/QuickGPX"

echo "==> Assembling bundle"
cp Config/App-Info.plist       "$CONTENTS/Info.plist"
cp Config/Preview-Info.plist   "$CONTENTS/PlugIns/GPXPreview.appex/Contents/Info.plist"
cp Config/Thumbnail-Info.plist "$CONTENTS/PlugIns/GPXThumbnail.appex/Contents/Info.plist"
cp "$BUILD/bin/QuickGPX"        "$CONTENTS/MacOS/QuickGPX"
cp "$BUILD/bin/GPXPreview"     "$CONTENTS/PlugIns/GPXPreview.appex/Contents/MacOS/GPXPreview"
cp "$BUILD/bin/GPXThumbnail"   "$CONTENTS/PlugIns/GPXThumbnail.appex/Contents/MacOS/GPXThumbnail"

if [ "$RELEASE" = 1 ]; then
    echo "==> Signing with Developer ID (hardened runtime)"
    SIGN=(--force --sign "$DEV_ID" --options runtime --timestamp)
else
    echo "==> Signing (ad-hoc)"
    SIGN=(--force --sign -)
fi
# Strip xattrs picked up from files that live in Dropbox (cp preserves them);
# codesign refuses to sign bundles carrying them.
xattr -cr "$APP" 2>/dev/null || true
codesign "${SIGN[@]}" --entitlements Config/preview.entitlements \
    "$CONTENTS/PlugIns/GPXPreview.appex"
codesign "${SIGN[@]}" --entitlements Config/thumbnail.entitlements \
    "$CONTENTS/PlugIns/GPXThumbnail.appex"
codesign "${SIGN[@]}" --entitlements Config/app.entitlements "$APP"

if [ "$RELEASE" = 1 ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Config/App-Info.plist)
    ZIP="dist/QuickGPX-$VERSION.zip"
    mkdir -p dist
    ditto -c -k --keepParent "$APP" "$ZIP"

    echo "==> Notarizing $ZIP (can take a few minutes)"
    if ! OUT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1); then
        echo "$OUT"
        cat <<'EOF'

Notarization failed. If credentials are not stored yet, run once:

  xcrun notarytool store-credentials notary \
      --apple-id nst021@gmail.com --team-id VBYRKYS73S \
      --password <app-specific-password from appleid.apple.com>

then rerun ./build.sh --release
EOF
        exit 1
    fi
    echo "$OUT"
    if ! echo "$OUT" | grep -q "status: Accepted"; then
        ID=$(echo "$OUT" | awk '/^  id: /{print $2; exit}')
        echo "Notarization not accepted. Details:"
        echo "  xcrun notarytool log $ID --keychain-profile $NOTARY_PROFILE"
        exit 1
    fi

    echo "==> Stapling ticket and repacking zip"
    xcrun stapler staple "$APP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "==> Distributable: $ZIP"
    spctl -a -vv "$APP" || true
fi

DEST="$HOME/Applications"
INSTALLED="$DEST/QuickGPX.app"
echo "==> Installing to $INSTALLED"
mkdir -p "$DEST"
rm -rf "$INSTALLED"
cp -R "$APP" "$INSTALLED"

echo "==> Registering with Launch Services and Quick Look"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$INSTALLED"
# pkd processes the deletion of the previous install asynchronously and can
# unregister the extensions AFTER we add them; verify and retry until both
# bundle ids are actually registered.
for attempt in 1 2 3 4 5 6 7 8; do
    pluginkit -a "$INSTALLED/Contents/PlugIns/GPXPreview.appex" || true
    pluginkit -a "$INSTALLED/Contents/PlugIns/GPXThumbnail.appex" || true
    pluginkit -e use -i com.nst.quickgpx.preview || true
    pluginkit -e use -i com.nst.quickgpx.thumbnail || true
    sleep 1
    # NB: not `pluginkit -m | grep -q`: grep -q SIGPIPEs pluginkit, which
    # under pipefail reports failure even when the extension is registered.
    REGISTERED=$(pluginkit -m 2>/dev/null || true)
    case "$REGISTERED" in
        *com.nst.quickgpx.preview*com.nst.quickgpx.thumbnail* | \
        *com.nst.quickgpx.thumbnail*com.nst.quickgpx.preview*)
            break ;;
    esac
    echo "    extensions not registered yet, retrying ($attempt)"
done
case "$(pluginkit -m 2>/dev/null || true)" in
    *com.nst.quickgpx.preview*) ;;
    *) echo "WARNING: preview extension failed to register; try running $0 again." ;;
esac
qlmanage -r >/dev/null
qlmanage -r cache >/dev/null
# ThumbnailsAgent caches its extension list; restart it so it picks up changes.
pkill -9 -f com.apple.quicklook.ThumbnailsAgent 2>/dev/null || true
# Finder's Quick Look panels are hosted by long-lived QuickLookUIService
# processes that keep the old appex loaded; replacing the binary under them
# breaks previews (blank map) until they restart. They respawn on demand.
pkill -9 -f QuickLookUIService 2>/dev/null || true

echo "==> Done. Select a .gpx file in Finder and press Space."
