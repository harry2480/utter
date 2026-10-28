import Foundation
import Synchronization
import UtterCore
import UtterPersistence
import UtterSpeech

@testable import UtteriOSKit

/// テストごとに一時ディレクトリを作り、終わったら消す。
final class TemporaryDirectory {
  let url: URL

  init() {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("utter-ios-tests-\(UUID().uuidString)", isDirectory: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

/// 録音の代わり。テストからチャンクや失敗を流せる
@MainActor
final class FakeRecorder: UtteriOSKit.AudioRecorder {
  struct StartFailure: Error {}

  let sampleRate = 16_000
  var permits = true
  var failsToStart = false
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var isRecording = false
  private var onChunk: (@Sendable (AudioChunk) -> Void)?
  private var onFailure: (@Sendable () -> Void)?
  /// これまでの start で渡された onFailure（古いセッションの失敗を流すため）
  private var failureHandlers: [@Sendable () -> Void] = []

  /// 設定すると、許可の確認を `grantPermission()` まで止める
  var holdsPermission = false
  private var pendingPermission: CheckedContinuation<Bool, Never>?

  func requestPermission() async -> Bool {
    guard holdsPermission else { return permits }
    return await withCheckedContinuation { pendingPermission = $0 }
  }

  var isAwaitingPermission: Bool { pendingPermission != nil }

  func grantPermission() {
    pendingPermission?.resume(returning: permits)
    pendingPermission = nil
  }

  func start(
    onChunk: @escaping @Sendable (AudioChunk) -> Void,
    onFailure: @escaping @Sendable () -> Void
  ) throws {
    startCount += 1
    if failsToStart { throw StartFailure() }
    self.onChunk = onChunk
    self.onFailure = onFailure
    failureHandlers.append(onFailure)
    isRecording = true
  }

  func stop() {
    stopCount += 1
    isRecording = false
  }

  /// `seconds` 秒分の無音を流す
  func emit(seconds: Double) {
    onChunk?(
      AudioChunk(
        samples: Array(repeating: 0, count: Int(seconds * Double(sampleRate))),
        sampleRate: sampleRate))
  }

  /// 指定したサンプルのチャンクを流す
  func emit(samples: [Float]) {
    onChunk?(AudioChunk(samples: samples, sampleRate: sampleRate))
  }

  func fail() {
    onFailure?()
  }

  /// `index` 回目（0 から）の start で渡された onFailure を呼ぶ
  func fail(startedAt index: Int) {
    failureHandlers[index]()
  }
}

/// コピーした本文を記録する
final class RecordingCopier: SharedResultTextCopier {
  private let copied = Mutex<[String]>([])

  var copiedTexts: [String] { copied.withLock { $0 } }

  func copy(_ text: String) async {
    copied.withLock { $0.append(text) }
  }
}

/// 進められる単調時計。待ち時間の注入で進める
final class TestClock: Sendable {
  private let current = Mutex(ContinuousClock.now)

  var now: ContinuousClock.Instant { current.withLock { $0 } }

  func advance(by duration: Duration) {
    current.withLock { $0 = $0.advanced(by: duration) }
  }
}

/// 条件を満たすまで待つ。非同期の認識・保存の完了を待つために使う
@MainActor
func waitUntil(
  timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while !condition() {
    if ContinuousClock.now >= deadline { return false }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return true
}

/// テストから好きなときにイベントを流せる音声認識。セッションごとに流し口を残す
final class ManualSpeechRecognizer: SpeechRecognizer {
  private let continuations = Mutex<[SessionID: AsyncStream<RecognitionEvent>.Continuation]>([:])

  func recognize(
    _ audio: AsyncStream<AudioChunk>, session: SessionID
  ) -> AsyncStream<RecognitionEvent> {
    let (stream, continuation) = AsyncStream.makeStream(of: RecognitionEvent.self)
    continuations.withLock { $0[session] = continuation }
    return stream
  }

  var sessions: [SessionID] { continuations.withLock { Array($0.keys) } }

  /// `session` の完了イベントを流す
  func complete(_ session: SessionID, text: String) {
    _ = continuations.withLock { $0[session] }?.yield(
      RecognitionEvent(sessionID: session, sequence: 0, kind: .completed(text)))
  }
}
