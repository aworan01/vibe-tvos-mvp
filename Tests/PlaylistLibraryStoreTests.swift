import XCTest
@testable import VibeTV

final class PlaylistLibraryStoreTests: XCTestCase {
    func testRoundTripsChannelsAndFavourites() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let channel = Channel(
            id: UUID(),
            name: "Synthetic HLS",
            streamURL: try XCTUnwrap(URL(string: "https://media.example.test/live.m3u8")),
            duration: -1,
            attributes: ["group-title": "Demo"],
            vlcOptions: [:],
            kodiProperties: [:],
            rawMetadataLines: ["#EXTINF:-1 group-title=\"Demo\",Synthetic HLS"]
        )
        let expected = SavedLibrary(channels: [channel], favourites: [channel.id])
        let store = PlaylistLibraryStore(directory: directory)

        try store.save(expected)

        XCTAssertEqual(try store.load(), expected)
    }

    func testFallsBackToSandboxedAtomicWriteWhenProtectionIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var attempts: [Data.WritingOptions] = []
        let store = PlaylistLibraryStore(directory: directory) { data, url, options in
            attempts.append(options)
            if options.contains(.completeFileProtection) {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: url, options: options)
        }
        let expected = SavedLibrary()

        try store.save(expected)

        XCTAssertEqual(attempts.count, 2)
        XCTAssertTrue(attempts[0].contains(.completeFileProtection))
        XCTAssertEqual(attempts[1], .atomic)
        XCTAssertEqual(try store.load(), expected)
    }
}
