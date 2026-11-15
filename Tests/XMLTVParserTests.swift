import XCTest
@testable import VibeTV

final class XMLTVParserTests: XCTestCase {
    func testParsesChannelNamesAndProgrammeTimes() throws {
        let now = Date(timeIntervalSince1970: 1_735_732_800)
        let guide = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="demo"><display-name>Demo Channel</display-name></channel>
          <programme start="20250101120000 +0000" stop="20250101130000 +0000" channel="demo">
            <title>News</title><sub-title>Midday</sub-title><desc>Latest headlines.</desc>
          </programme>
        </tv>
        """

        let programme = try XCTUnwrap(
            XMLTVParser.parse(Data(guide.utf8), now: now).first
        )

        XCTAssertEqual(programme.channelID, "demo")
        XCTAssertEqual(programme.channelName, "Demo Channel")
        XCTAssertEqual(programme.title, "News")
        XCTAssertEqual(programme.subtitle, "Midday")
    }
}
