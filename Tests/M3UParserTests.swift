import XCTest
@testable import VibeTV

final class M3UParserTests: XCTestCase {
    func testPreservesExtendedMetadataAndDetectsClearKeyDASH() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1 tvg-id="sample.one" tvg-logo="https://assets.example.test/logo.png" group-title="Demo",Demo Channel
        #EXTVLCOPT:http-user-agent=Example Player
        #KODIPROP:inputstream.adaptive.manifest_type=mpd
        #KODIPROP:inputstream.adaptive.license_type=clearkey
        #KODIPROP:inputstream.adaptive.license_key=synthetic-test-value
        https://media.example.test/demo/manifest.mpd
        """

        let channel = try XCTUnwrap(M3UParser().parse(input).first)
        XCTAssertEqual(channel.name, "Demo Channel")
        XCTAssertEqual(channel.attributes["tvg-id"], "sample.one")
        XCTAssertEqual(channel.vlcOptions["http-user-agent"], "Example Player")
        XCTAssertEqual(channel.kodiProperties["inputstream.adaptive.manifest_type"], "mpd")
        XCTAssertEqual(channel.rawMetadataLines.count, 5)
        XCTAssertEqual(channel.capability.container, .dash)
        XCTAssertEqual(channel.capability.drm, .clearKey)
        XCTAssertFalse(channel.capability.isNativelyPlayable)
    }

    func testIdentifiesPlainHLSAsNativelyPlayable() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1 group-title="Demo",HLS Channel
        https://media.example.test/live/index.m3u8
        """
        let channel = try XCTUnwrap(M3UParser().parse(input).first)
        XCTAssertEqual(channel.capability.container, .hls)
        XCTAssertEqual(channel.capability.drm, .none)
        XCTAssertTrue(channel.capability.isNativelyPlayable)
    }

    func testReadsEmbeddedXMLTVURL() throws {
        let input = """
        #EXTM3U url-tvg="https://guide.example.test/epg.xml"
        #EXTINF:-1,Demo
        https://media.example.test/live.m3u8
        """

        XCTAssertEqual(
            M3UParser.guideURL(in: Data(input.utf8))?.absoluteString,
            "https://guide.example.test/epg.xml"
        )
    }

    func testParsesSyntheticClearKeyConfiguration() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1,Demo DASH
        #EXTVLCOPT:http-user-agent=Example Player
        #KODIPROP:inputstream.adaptive.manifest_type=mpd
        #KODIPROP:inputstream.adaptive.license_type=clearkey
        #KODIPROP:inputstream.adaptive.license_key={"keys":[{"kty":"oct","kid":"AAECAwQFBgcICQoLDA0ODw","k":"ABEiM0RVZneImaq7zN3u_w"}]}
        https://media.example.test/manifest.mpd
        """

        let channel = try XCTUnwrap(M3UParser().parse(input).first)

        XCTAssertNotNil(channel.clearKey)
        XCTAssertEqual(channel.clearKey?.userAgent, "Example Player")
    }
}

