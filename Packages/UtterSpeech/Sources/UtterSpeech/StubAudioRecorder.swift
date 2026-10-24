import Synchronization
import UtterCore

/// 固定のサンプルを流すテスト用の録音（REC-04, REC-05）。
///
/// 本番と同じ規則で動く。開始前にマイクの使用許可を確かめ、同時に1つだけ録音する。
/// 録音中や開始の途中の `start` は `.alreadyRecording` を投げ、開始の途中の `stop()` で開始を取りやめる。
/// 録音中は `feed(_:)` でサンプルを足し、`interrupt(_:)` で OS の割り込みによる停止を再現できる。
public final class StubAudioRecorder: AudioRecorder {
  private let microphone: any MicrophoneAccess
  private let sampleRate: Int
  private let startError: AudioRecorderError?
  private let state = Mutex<(phase: Phase, lastAttempt: UInt64)>((.idle, 0))

  private enum Phase {
    case idle
    case starting(attempt: UInt64)
    case recording(AudioRecordingPipeline)
  }

  /// - Parameters:
  ///   - microphone: マイクの使用許可
  ///   - sampleRate: 流すサンプルのサンプリング周波数（Hz）
  ///   - startError: 使用許可を確かめた後に投げる失敗（入力機器がないなど）
  public init(
    microphone: any MicrophoneAccess = StubMicrophoneAccess(authorization: .authorized),
    sampleRate: Int = AudioRecordingPipeline.defaultSampleRate,
    startError: AudioRecorderError? = nil
  ) {
    self.microphone = microphone
    self.sampleRate = sampleRate
    self.startError = startError
  }

  /// 録音中なら `true`
  public var isRecording: Bool {
    pipeline() != nil
  }

  public func start(buffer: AudioStreamBuffer) async throws(AudioRecorderError) -> AudioRecording {
    let attempt = try state.withLock { state throws(AudioRecorderError) -> UInt64 in
      switch state.phase {
      case .idle: break
      case .starting: throw .alreadyRecording
      case .recording(let pipeline):
        // 終わった録音は片付けて、新しい録音を始められるようにする
        guard pipeline.isEnded else { throw .alreadyRecording }
      }
      state.lastAttempt += 1
      state.phase = .starting(attempt: state.lastAttempt)
      return state.lastAttempt
    }

    let failure: AudioRecorderError?
    do throws(AudioRecorderError) {
      try await microphone.ensureAccess()
      failure = startError
    } catch {
      failure = error
    }

    let sampleRate = sampleRate
    return try state.withLock { state throws(AudioRecorderError) -> AudioRecording in
      // 許可を待つ間に stop() が呼ばれていたら始めない
      guard case .starting(let current) = state.phase, current == attempt else {
        throw .cancelled
      }
      if let failure {
        state.phase = .idle
        throw failure
      }
      let (pipeline, recording) = AudioRecordingPipeline.make(
        buffer: buffer, sampleRate: sampleRate)
      state.phase = .recording(pipeline)
      return recording
    }
  }

  public func stop() async {
    let pipeline = state.withLock { state -> AudioRecordingPipeline? in
      switch state.phase {
      case .idle:
        return nil
      case .starting:
        state.phase = .idle
        return nil
      case .recording(let pipeline):
        state.phase = .idle
        return pipeline
      }
    }
    pipeline?.end(.finished)
  }

  /// 録音中ならモノラルのサンプルを足す
  public func feed(_ samples: [Float]) {
    pipeline()?.append(samples)
  }

  /// OS の割り込みで録音が止まったことにする
  public func interrupt(_ interruption: RecordingInterruption) {
    pipeline()?.end(.interrupted(interruption))
  }

  /// 終わっていない録音
  private func pipeline() -> AudioRecordingPipeline? {
    state.withLock { state in
      guard case .recording(let pipeline) = state.phase, !pipeline.isEnded else { return nil }
      return pipeline
    }
  }
}
