import Synchronization
import Testing
import UtterCore

@testable import UtterSpeech

struct StubAudioRecorderTests {
  private func collect<Element>(_ stream: AsyncStream<Element>) async -> [Element] {
    var received: [Element] = []
    for await element in stream {
      received.append(element)
    }
    return received
  }

  @Test("PERM-01: 使用許可がなければ録音を始めない")
  func deniedDoesNotStart() async {
    let recorder = StubAudioRecorder(
      microphone: StubMicrophoneAccess(authorization: .notDetermined, grantsOnRequest: false))

    await #expect(throws: AudioRecorderError.microphoneAccessDenied) {
      _ = try await recorder.start(buffer: AudioStreamBuffer())
    }
    #expect(!recorder.isRecording)
  }

  @Test("REC-04: 録音中にもう一度始めようとしても、2つ目の録音を始めない（連打）")
  func rejectsSecondStart() async throws {
    let recorder = StubAudioRecorder()
    let recording = try await recorder.start(buffer: AudioStreamBuffer())

    await #expect(throws: AudioRecorderError.alreadyRecording) {
      _ = try await recorder.start(buffer: AudioStreamBuffer())
    }

    // 1つ目の録音は続いている
    recorder.feed(Array(repeating: 0.5, count: 1_600))
    await recorder.stop()
    #expect(await collect(recording.chunks).count == 1)
  }

  @Test("REC-04: 止めた後は新しい録音を始められ、止める操作を重ねても問題ない")
  func restartAfterStop() async throws {
    let recorder = StubAudioRecorder()
    let first = try await recorder.start(buffer: AudioStreamBuffer())
    await recorder.stop()
    await recorder.stop()

    let second = try await recorder.start(buffer: AudioStreamBuffer())

    #expect(await collect(first.ends).map(\.reason) == [.finished])
    #expect(recorder.isRecording)
    recorder.interrupt(.audioInterruptionBegan)
    #expect(await collect(second.ends).map(\.reason) == [.interrupted(.audioInterruptionBegan)])
  }

  @Test("REC-04: 割り込みで止まった長さを、割り込みの対応方針にそのまま渡せる")
  func interruptionFeedsPolicy() async throws {
    let recorder = StubAudioRecorder()
    let recording = try await recorder.start(buffer: AudioStreamBuffer())
    recorder.feed(Array(repeating: 0.5, count: 8_000))
    recorder.interrupt(.audioRouteChanged(.inputDeviceLost))

    let end = try #require(await collect(recording.ends).first)
    guard case .interrupted(let interruption) = end.reason else {
      Issue.record("割り込みで止まっていない")
      return
    }
    #expect(end.capturedDuration == .milliseconds(500))
    #expect(
      RecordingInterruptionPolicy().decision(
        for: interruption, capturedAudioDuration: end.capturedDuration)
        == .stopAndProcess(.inputDeviceLost))
  }

  @Test("REC-04: 使用許可を待つ間にもう一度始めようとしても、2つ目を始めず許可も求め直さない（連打）")
  func rejectsStartWhileWaitingForPermission() async throws {
    let microphone = GatedMicrophoneAccess()
    let recorder = StubAudioRecorder(microphone: microphone)
    let first = Task { try await recorder.start(buffer: AudioStreamBuffer()) }
    await microphone.waitUntilRequested()

    await #expect(throws: AudioRecorderError.alreadyRecording) {
      _ = try await recorder.start(buffer: AudioStreamBuffer())
    }
    microphone.answer(true)

    _ = try await first.value
    #expect(recorder.isRecording)
    #expect(microphone.requestCount == 1)
  }

  @Test("REC-04: 使用許可を待つ間に止めたら、許可されても録音を始めない")
  func stopWhileWaitingForPermissionCancels() async {
    let microphone = GatedMicrophoneAccess()
    let recorder = StubAudioRecorder(microphone: microphone)
    let first = Task { try await recorder.start(buffer: AudioStreamBuffer()) }
    await microphone.waitUntilRequested()

    await recorder.stop()
    microphone.answer(true)

    await #expect(throws: AudioRecorderError.cancelled) {
      _ = try await first.value
    }
    #expect(!recorder.isRecording)
  }

  @Test("REC-04: 割り込みで終わった直後に、新しい録音を始められる")
  func restartRightAfterInterruption() async throws {
    let recorder = StubAudioRecorder()
    _ = try await recorder.start(buffer: AudioStreamBuffer())
    recorder.interrupt(.audioInterruptionBegan)

    _ = try await recorder.start(buffer: AudioStreamBuffer())
    #expect(recorder.isRecording)
  }
}

/// 利用者が答えるまで許可の要求を待たせる `MicrophoneAccess`
private final class GatedMicrophoneAccess: MicrophoneAccess {
  private let state = Mutex<(count: Int, answer: CheckedContinuation<Bool, Never>?)>((0, nil))
  private let requested: AsyncStream<Void>
  private let requestedContinuation: AsyncStream<Void>.Continuation

  init() {
    (requested, requestedContinuation) = AsyncStream.makeStream(of: Void.self)
  }

  var requestCount: Int { state.withLock { $0.count } }

  func authorization() async -> MicrophoneAuthorization { .notDetermined }

  func requestAccess() async -> Bool {
    await withCheckedContinuation { continuation in
      state.withLock {
        $0.count += 1
        $0.answer = continuation
      }
      requestedContinuation.yield()
    }
  }

  func waitUntilRequested() async {
    for await _ in requested { return }
  }

  func answer(_ granted: Bool) {
    state.withLock { state in
      state.answer?.resume(returning: granted)
      state.answer = nil
    }
  }
}
