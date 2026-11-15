# Vibe TV

An initial native SwiftUI media-player skeleton for tvOS 17 and later.

## Included

- Home, Movies, Series, Live TV, Search, and Library navigation
- Extended M3U parsing with preservation of EXTINF, EXTVLCOPT, and KODIPROP
- HLS, DASH, ClearKey, and Widevine capability assessment
- Basic HLS playback through AVPlayer
- Local-network M3U upload using a one-time six-digit code
- Persistent on-device channel library protected by Apple file protection
- EPG auto-match and TMDB client scaffolding
- Synthetic parser tests with no real stream addresses or DRM credentials
- Layered Vibe TV app icon for the Apple TV Home Screen

## Create the Xcode project

1. Install Xcode 15.3 or later and XcodeGen on macOS.
2. Run 'xcodegen generate' in this directory.
3. Open VibeTV.xcodeproj, select an Apple TV simulator, and run.

GitHub Actions compiles the app and its test bundle against the generic tvOS
Simulator destination. Running the tests requires a macOS machine with a tvOS
Simulator runtime installed.

Each successful GitHub Actions run also builds a Release app for physical Apple
TV hardware and uploads 'VibeTV-unsigned.ipa' with its SHA-256 checksum under
the run's Artifacts section. The IPA is unsigned and must be signed with an
appropriate Apple development certificate and provisioning profile before it
can be installed.

The repository intentionally excludes playlists and secrets. Imported playlist metadata remains on the device. Do not commit provider URLs, HTTP headers, license URLs, tokens, or DRM key material.

## Import a local playlist

On Apple TV, open Live TV, choose Import, and leave the import screen open.
The app displays a temporary local address and a six-digit code. Open that
address on a phone or computer connected to the same trusted network, choose
an M3U file, enter the code, and send it. Uploads are limited to 8 MB, the code
accepts one successful upload, and ten incorrect code attempts disable it.

The parsed library is saved inside the private app sandbox and restored when
the app launches again. Storage tries Application Support, Documents, and then
Caches. At each location, the app requests complete file protection first and
falls back to an atomic sandboxed write when tvOS rejects lock-state
protection. Caches is a last resort and tvOS may purge it when storage is low.
Reinstalling or deleting the app removes this local library.

## Current playback limits

AVPlayer handles ordinary HLS sources supported by tvOS. The app detects DASH, ClearKey, and Widevine so the UI can explain their capabilities, but this MVP does not implement those playback paths. Widevine is not natively supported by AVPlayer on tvOS. A production DRM integration requires authorization from the content provider and an appropriate playback SDK or Apple FairPlay workflow.

TMDB and EPG services are protocols with placeholder implementations. Add credentials through a local, ignored configuration file or secure service; never hard-code them.

