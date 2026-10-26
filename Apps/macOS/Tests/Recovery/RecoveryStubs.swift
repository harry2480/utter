import Foundation
import Synchronization
import UtterCore
import UtterPersistence
import UtterSpeech

/// テストごとに一時ディレクトリを作り、終わったら消す。
final class TemporaryAudioDirectory {
  let url: URL

  init() {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("utter-mac-tests-\(UUID().uuidString)", isDirectory: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }

  /// 固定の時刻で保存する一時音声のストア
  func store(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws -> TemporaryAudioStore {
    try TemporaryAudioStore(directory: url, now: { now })
  }
}

/// 復旧の問い合わせに決めた答えを返し、記録する。
@MainActor
final class StubAudioRecoveryPrompt: AudioRecoveryPrompting {
  var answer: Bool
  private(set) var askedCounts: [Int] = []
  private(set) var reportedUnrecovered: [Int] = []

  init(answer: Bool) {
    self.answer = answer
  }

  /// 尋ねられたときに呼ぶ（新しいセッションを止めているかの確認に使う）
  var onAsk: (() -> Void)?

  func confirmRecovery(count: Int) async -> Bool {
    askedCounts.append(count)
    onAsk?()
    return answer
  }

  func reportUnrecovered(count: Int) {
    reportedUnrecovered.append(count)
  }
}

/// プレビューに出した文字列を記録する。
@MainActor
final class StubRecoveryPreview: InsertionPreviewPresenting {
  private(set) var shown: [(text: String, cause: InsertionPreviewCause)] = []

  func showPreview(text: String, cause: InsertionPreviewCause) {
    shown.append((text, cause))
  }
}

/// 依頼されたセッションID と受け取ったサンプル数を記録し、決めた手順で認識する。
final class RecordingSpeechRecognizer: SpeechRecognizer {
  private let base: StubSpeechRecognizer
  private let requests = Mutex<[SessionID]>([])

  init(steps: [StubSpeechRecognizer.Step]) {
    base = StubSpeechRecognizer(steps: steps)
  }

  var sessions: [SessionID] {
    requests.withLock { $0 }
  }

  func recognize(
    _ audio: AsyncStream<AudioChunk>, session: SessionID
  ) -> AsyncStream<RecognitionEvent> {
    requests.withLock { $0.append(session) }
    return base.recognize(audio, session: session)
  }
}

/// 決めた回数だけ「待機中でない」と答えてから止める。止めている間かを記録する。
@MainActor
final class StubRecoveryGate: RecoverySessionGate {
  private var busyAnswers: Int
  private(set) var isSuspended = false
  private(set) var suspendAttempts = 0
  /// 確認を尋ねた時点・認識した時点で止めていたか
  var wasSuspendedWhen: [Bool] = []

  init(busyAnswers: Int = 0) {
    self.busyAnswers = busyAnswers
  }

  func suspendIfIdle() -> Bool {
    suspendAttempts += 1
    guard busyAnswers == 0 else {
      busyAnswers -= 1
      return false
    }
    isSuspended = true
    return true
  }

  func resume() {
    isSuspended = false
  }
}
