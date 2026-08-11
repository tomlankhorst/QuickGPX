# QuickGPX

<IMG SRC="quickgpx.jpg" WIDTH="800" ALT="QuickGPX, macOS QuickLook plugin for GPX files">

macOS Quick Look support for `.gpx` files:

- **Press Space on a GPX file in Finder** → the track drawn on a Thunderforest Outdoors base map ("Outdoor" layer), titled with the start location + date, plus a stats bar: distance (km), D+ (cumulative ascent), altitude range, duration (when the file has timestamps), and point count. An elevation profile (altitude vs. distance) is drawn under the map when the file carries elevation data; hovering it shows a crosshair with distance/altitude and marks the spot on the map.

- **Finder thumbnails** → the track outline drawn as the file's icon.

Legacy `.qlgenerator` plugins stopped working in macOS 15 (Sequoia), so this is
built the modern way: a minimal host app carrying a Quick Look **preview
extension** (`QLPreviewingController` + MapKit) and a **thumbnail extension**
(`QLThumbnailProvider`). No Xcode project — everything is compiled with `swiftc`
and assembled by the build script.

## Build & install

```sh
./build.sh
```

This compiles, assembles `QuickGPX.app`, ad-hoc signs it, installs it to
`~/Applications`, and registers the extensions. Then select any `.gpx` file in
Finder and press Space. Requires Xcode (or at least its toolchain + SDK).

If previews don't appear: check that "QuickGPX" is enabled under
System Settings → General → Login Items & Extensions → Quick Look.

## Release (distributable build)

```sh
./build.sh --release
```

Signs with Developer ID (hardened runtime + timestamp), notarizes, staples,
and writes a distributable `dist/QuickGPX-<version>.zip`. One-time setup for
notarization credentials:

```sh
xcrun notarytool store-credentials notary \
    --apple-id <apple-id> --team-id VBYRKYS73S \
    --password <app-specific-password>   # from appleid.apple.com
```

Not App Store material: the sbpl entitlement below would be rejected by review
(notarization, being a malware scan rather than a policy review, accepts it).

## Uninstall

```sh
rm -rf ~/Applications/QuickGPX.app && qlmanage -r
```

## Layout

```
Sources/Shared/GPXDocument.swift        GPX parser (trk/rte/wpt) + stats
Sources/Preview/PreviewViewController.swift   map preview extension
Sources/Thumbnail/ThumbnailProvider.swift     thumbnail extension
Sources/App/main.swift                  minimal host app
Config/                                 Info.plists + entitlements
build.sh                                compile, bundle, sign, install, register
```

## Notes on the Quick Look sandbox

Quick Look preview extensions run under the system's `quicklook-preview.sb`
sandbox profile, which **denies all networking** regardless of the
`com.apple.security.network.client` entitlement. Consequences:

- Apple's own map tiles can never load (GeoServices is blocked), so the map
  uses an `MKTileOverlay` with `canReplaceMapContent` fetching web tiles directly.
  Thunderforest Outdoors @2x is used because openstreetmap.org serves only
  256px tiles, which are blurry at readable label size on Retina (`tileSize`
  512 cancels MapKit's Retina zoom offset).
- The network access needed for those tile fetches is granted through
  `com.apple.security.temporary-exception.sbpl` entitlements
  (`(allow network-outbound)`), which the profile explicitly honors.
- The title's location comes from OSM Nominatim reverse geocoding (zoom 16);
  Apple's `CLGeocoder` needs geod, which the sandbox blocks.

The thumbnail extension needs no network — it draws the track vector directly.

macOS caches aggressively: `build.sh` runs `qlmanage -r`, resets the cache, and
restarts `ThumbnailsAgent`, which otherwise keeps serving a stale extension list.
