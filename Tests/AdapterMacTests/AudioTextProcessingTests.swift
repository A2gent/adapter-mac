import XCTest
@testable import adapter_mac

final class AudioTextProcessingTests: XCTestCase {
    func testNormalizedSpeechTextStripsMarkdownAndSpeaksLinksAsDomains() {
        let input = """
        # Release Notes

        Visit https://example.com/docs?token=secret.

        | Name | Value |
        | ---- | ----- |
        | Foo  | Bar   |

        `inline code`
        **bold** text
        """

        XCTAssertEqual(
            AudioTextNormalizer.normalizedSpeechText(from: input),
            "Release Notes. Visit link to example.com bold text"
        )
    }

    func testMarkdownTableSeparatorDetectionRequiresAtLeastTwoColumns() {
        XCTAssertTrue(AudioTextNormalizer.isMarkdownTableSeparatorLine("| --- | :---: |"))
        XCTAssertFalse(AudioTextNormalizer.isMarkdownTableSeparatorLine("---"))
        XCTAssertFalse(AudioTextNormalizer.isMarkdownTableSeparatorLine("| nope | maybe |"))
    }

    func testReplacingURLsWithDomainSpeechPreservesTrailingPunctuationOutsideReplacement() {
        XCTAssertEqual(
            AudioTextNormalizer.replaceURLsWithDomainSpeech(in: "See www.example.com/docs, please!"),
            "See  link to www.example.com  please!"
        )
    }

    func testNormalizedWaveformLevelClampsAndLiftsQuietSpeech() {
        XCTAssertEqual(AudioWaveformNormalizer.normalizedWaveformLevel(from: 0), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(AudioWaveformNormalizer.normalizedWaveformLevel(from: 0.02), 0)
        XCTAssertEqual(AudioWaveformNormalizer.normalizedWaveformLevel(from: 1), 1, accuracy: 0.0001)
    }
}
