import XCTest
@testable import adapter_mac

@MainActor
final class TranscriptionProviderTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: "selectedTranscriptionProvider")
        UserDefaults.standard.removeObject(forKey: "selectedLocalWhisperCPPModelID")
    }

    func testAPIBaseURLRemovesSpeechTranscribeSuffix() {
        XCTAssertEqual(
            WhisperService.apiBaseURL(from: "http://localhost:5445/speech/transcribe")?.absoluteString,
            "http://localhost:5445"
        )
    }

    func testAPIBaseURLRemovesGenericTranscribeSuffixAndPreservesPath() {
        XCTAssertEqual(
            WhisperService.apiBaseURL(from: "https://example.com/api/transcribe")?.absoluteString,
            "https://example.com/api"
        )
    }

    func testSelectedTranscriptionProviderDefaultsToBruteHTTP() {
        XCTAssertEqual(TranscriptionSettings.selectedProvider, .bruteHTTP)
    }

    func testSelectedTranscriptionProviderPersistsLocalFluidAudio() {
        TranscriptionSettings.selectedProvider = .localFluidAudio

        XCTAssertEqual(TranscriptionSettings.selectedProvider, .localFluidAudio)
    }

    func testSelectedTranscriptionProviderPersistsLocalWhisperCPP() {
        TranscriptionSettings.selectedProvider = .localWhisperCPP

        XCTAssertEqual(TranscriptionSettings.selectedProvider, .localWhisperCPP)
    }

    func testProviderFactoryReturnsInjectedBruteProviderWhenSelected() {
        let bruteProvider = StubTranscriptionProvider(result: .success("brute"))
        let localFluidProvider = StubTranscriptionProvider(result: .success("fluid"))
        let localWhisperProvider = StubTranscriptionProvider(result: .success("whisper"))
        let factory = TranscriptionProviderFactory(
            bruteProvider: bruteProvider,
            localFluidAudioProvider: localFluidProvider,
            localWhisperCPPProvider: localWhisperProvider
        )

        TranscriptionSettings.selectedProvider = .bruteHTTP

        let provider = factory.makeSelectedProvider()

        XCTAssertTrue(provider === bruteProvider)
    }

    func testProviderFactoryReturnsInjectedLocalFluidAudioProviderWhenSelected() {
        let bruteProvider = StubTranscriptionProvider(result: .success("brute"))
        let localFluidProvider = StubTranscriptionProvider(result: .success("fluid"))
        let localWhisperProvider = StubTranscriptionProvider(result: .success("whisper"))
        let factory = TranscriptionProviderFactory(
            bruteProvider: bruteProvider,
            localFluidAudioProvider: localFluidProvider,
            localWhisperCPPProvider: localWhisperProvider
        )

        TranscriptionSettings.selectedProvider = .localFluidAudio

        let provider = factory.makeSelectedProvider()

        XCTAssertTrue(provider === localFluidProvider)
    }

    func testProviderFactoryReturnsInjectedLocalWhisperCPPProviderWhenSelected() {
        let bruteProvider = StubTranscriptionProvider(result: .success("brute"))
        let localFluidProvider = StubTranscriptionProvider(result: .success("fluid"))
        let localWhisperProvider = StubTranscriptionProvider(result: .success("whisper"))
        let factory = TranscriptionProviderFactory(
            bruteProvider: bruteProvider,
            localFluidAudioProvider: localFluidProvider,
            localWhisperCPPProvider: localWhisperProvider
        )

        TranscriptionSettings.selectedProvider = .localWhisperCPP

        let provider = factory.makeSelectedProvider()

        XCTAssertTrue(provider === localWhisperProvider)
    }

    func testSelectedLocalWhisperCPPModelDefaultsToTinyEnglish() {
        XCTAssertEqual(LocalWhisperCPPModelSettings.selectedModelID, WhisperCPPModelCatalog.defaultModel.id)
    }

    func testSelectedLocalWhisperCPPModelPersistsCustomChoice() throws {
        let customModel = try XCTUnwrap(
            WhisperCPPModelCatalog.availableModels.first { $0.id != WhisperCPPModelCatalog.defaultModel.id }
        )

        LocalWhisperCPPModelSettings.selectedModelID = customModel.id

        XCTAssertEqual(LocalWhisperCPPModelSettings.selectedModelID, customModel.id)
        XCTAssertEqual(LocalWhisperCPPModelSettings.selectedModel.id, customModel.id)
    }

    func testAppDelegateTranscriptionUsesInjectedProviderResult() {
        let expectedText = "hello from provider"
        let provider = StubTranscriptionProvider(result: .success(expectedText))
        let appDelegate = AppDelegate(transcriptionProviderFactory: StubTranscriptionProviderFactory(provider: provider))
        let expectation = expectation(description: "transcription completion")

        appDelegate.requestTranscription(for: URL(fileURLWithPath: "/tmp/test-audio.wav")) { result in
            switch result {
            case .success(let text):
                XCTAssertEqual(text, expectedText)
            case .failure(let error):
                XCTFail("Expected success, got error: \(error)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(provider.transcribeCallCount, 1)
    }
}

private final class StubTranscriptionProvider: TranscriptionProvider {
    let result: Result<String, Error>
    private(set) var transcribeCallCount = 0
    private(set) var lastAudioURL: URL?

    var apiEndpoint: String = "http://localhost:5445/speech/transcribe"

    init(result: Result<String, Error>) {
        self.result = result
    }

    func updateAPIEndpoint(_ endpoint: String?) {
        apiEndpoint = endpoint ?? ""
    }

    func transcribe(audioURL: URL, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        transcribeCallCount += 1
        lastAudioURL = audioURL
        completion(result)
    }
}

private struct StubTranscriptionProviderFactory: TranscriptionProvidingFactory {
    let provider: TranscriptionProvider

    func makeSelectedProvider() -> TranscriptionProvider {
        provider
    }
}
