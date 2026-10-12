import Testing

@testable import UtterCore

struct SessionConfigurationTests {
  @Test("REC-05: 最大録音時間の既定は300秒")
  func defaultMaxRecordingDurationIs300Seconds() {
    #expect(SessionConfiguration().maxRecordingDuration == .seconds(300))
  }

  @Test("REC-05: 0以下の最大録音時間は拒否する", arguments: [Duration.zero, .seconds(-1)])
  func rejectsNonPositiveMaxRecordingDuration(_ duration: Duration) {
    #expect(throws: SessionConfigurationError.nonPositiveMaxRecordingDuration) {
      try SessionConfiguration(maxRecordingDuration: duration)
    }
  }
}
