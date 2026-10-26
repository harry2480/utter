import Testing

@testable import UtterSpeech

struct WhisperKitRecognizerConfigurationTests {
  @Test("REC-06: 既定の設定は無効で、仮置きの値（日本語・1秒ごと・末尾2区間を未確定）を持つ")
  func defaultsAreDisabled() throws {
    let configuration = try WhisperKitRecognizerConfiguration()

    #expect(!configuration.isEnabled)
    #expect(configuration.language == "ja")
    #expect(configuration.transcriptionInterval == .seconds(1))
    #expect(configuration.requiredSegmentsForConfirmation == 2)
    #expect(configuration == .disabled)
  }

  @Test("REC-06: 推論し直す間隔をサンプル数にする（端数は切り上げ、最小1）")
  func convertsIntervalToSampleCount() throws {
    #expect(try configuration(interval: .seconds(1)).transcriptionIntervalSampleCount == 16_000)
    #expect(
      try configuration(interval: .milliseconds(500)).transcriptionIntervalSampleCount == 8_000)
    #expect(try configuration(interval: .nanoseconds(1)).transcriptionIntervalSampleCount == 1)
    #expect(try configuration(interval: .seconds(30)).transcriptionIntervalSampleCount == 480_000)
  }

  @Test("REC-06: 空の言語・0以下や30秒を超える間隔・1未満の区間数を拒否する")
  func rejectsInvalidValues() {
    #expect(throws: WhisperKitRecognizerConfigurationError.emptyLanguage) {
      try WhisperKitRecognizerConfiguration(language: "")
    }
    #expect(throws: WhisperKitRecognizerConfigurationError.nonPositiveTranscriptionInterval) {
      try WhisperKitRecognizerConfiguration(transcriptionInterval: .zero)
    }
    #expect(throws: WhisperKitRecognizerConfigurationError.transcriptionIntervalTooLong) {
      try WhisperKitRecognizerConfiguration(transcriptionInterval: .seconds(31))
    }
    #expect(throws: WhisperKitRecognizerConfigurationError.nonPositiveRequiredSegments) {
      try WhisperKitRecognizerConfiguration(requiredSegmentsForConfirmation: 0)
    }
  }

  private func configuration(interval: Duration) throws -> WhisperKitRecognizerConfiguration {
    try WhisperKitRecognizerConfiguration(transcriptionInterval: interval)
  }
}
