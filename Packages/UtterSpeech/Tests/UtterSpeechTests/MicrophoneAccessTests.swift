import Testing

@testable import UtterSpeech

struct MicrophoneAccessTests {
  @Test("PERM-01: 未確認なら録音の前に許可を求め、許可されたら録音できる")
  func requestsWhenNotDetermined() async throws {
    let microphone = StubMicrophoneAccess(authorization: .notDetermined, grantsOnRequest: true)

    try await microphone.ensureAccess()

    #expect(microphone.requestCount == 1)
    #expect(await microphone.authorization() == .authorized)
  }

  @Test("PERM-01: 初めての要求で拒否されたら録音しない")
  func throwsWhenRequestDenied() async {
    let microphone = StubMicrophoneAccess(authorization: .notDetermined, grantsOnRequest: false)

    await #expect(throws: AudioRecorderError.microphoneAccessDenied) {
      try await microphone.ensureAccess()
    }
    #expect(microphone.requestCount == 1)
  }

  @Test(
    "PERM-01: 拒否・制限されていれば要求し直さずに録音しない",
    arguments: [
      (MicrophoneAuthorization.denied, AudioRecorderError.microphoneAccessDenied),
      (.restricted, .microphoneAccessRestricted),
    ])
  func throwsWithoutRequestWhenRefused(
    authorization: MicrophoneAuthorization, expected: AudioRecorderError
  ) async {
    let microphone = StubMicrophoneAccess(authorization: authorization)

    await #expect(throws: expected) {
      try await microphone.ensureAccess()
    }
    #expect(microphone.requestCount == 0)
  }

  @Test("PERM-01: 許可済みなら要求しない")
  func doesNotRequestWhenAuthorized() async throws {
    let microphone = StubMicrophoneAccess(authorization: .authorized)

    try await microphone.ensureAccess()

    #expect(microphone.requestCount == 0)
  }
}
