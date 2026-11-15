# Vibe TV

An initial native SwiftUI media-player skeleton for tvOS 17 and later.

## Included

- Home, Movies, Series, Live TV, Search, and Library navigation
- Extended M3U parsing with preservation of EXTINF, EXTVLCOPT, and KODIPROP
- HLS, DASH, ClearKey, and Widevine capability assessment
- Basic HLS playback through AVPlayer
- EPG auto-match and TMDB client scaffolding
- Synthetic parser tests with no real stream addresses or DRM credentials

## Create the Xcode project

1. Install Xcode 15.3 or later and XcodeGen on macOS.
2. Run 'xcodegen generate' in this directory.
3. Open VibeTV.xcodeproj, select an Apple TV simulator, and run.

GitHub Actions compiles the app and its test bundle against the generic tvOS
Simulator destination. Running the tests requires a macOS machine with a tvOS
Simulator runtime installed.

The repository intentionally excludes playlists and secrets. Imported playlist metadata remains on the device. Do not commit provider URLs, HTTP headers, license URLs, tokens, or DRM key material.

## Current playback limits

AVPlayer handles ordinary HLS sources supported by tvOS. The app detects DASH, ClearKey, and Widevine so the UI can explain their capabilities, but this MVP does not implement those playback paths. Widevine is not natively supported by AVPlayer on tvOS. A production DRM integration requires authorization from the content provider and an appropriate playback SDK or Apple FairPlay workflow.

TMDB and EPG services are protocols with placeholder implementations. Add credentials through a local, ignored configuration file or secure service; never hard-code them.

