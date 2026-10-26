import Foundation
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

/// 起動時の復旧を利用者に尋ねる（7章, AC-10）。本番は `AudioRecoveryAlert`、テストは Stub。
///
/// 尋ねる文言・知らせる文言に発話本文・セッションID・ファイルの場所を出さない（件数だけ）。
@MainActor
protocol AudioRecoveryPrompting: AnyObject {
  /// 前回の終了前に処理を終えられなかった録音を復旧するか尋ねる。復旧するなら `true`、削除するなら `false`
  func confirmRecovery(count: Int) async -> Bool
  /// 復旧を選んだが戻せなかった録音の件数を知らせる。音声は残し、次回起動時にもう一度尋ねる
  func reportUnrecovered(count: Int)
}

/// 起動時の復旧の間、新しいセッションを始めないようにする（本番は `SessionCoordinator`）。
@MainActor
protocol RecoverySessionGate: AnyObject {
  /// 待機中なら新しいセッションを始めないようにして `true`。待機中でなければ何もせず `false`
  func suspendIfIdle() -> Bool
  func resume()
}

extension SessionCoordinator: RecoverySessionGate {}

/// アプリの異常終了後の起動時に、一時音声から発話を戻す（7章, AC-10）。
///
/// 1. `start()` で起動時の整理（保持期限を過ぎた音声の削除）と復旧候補の取得を、保存・削除のキューの先頭で行う
/// 2. 候補があれば、セッションが待機中になるのを待って新しいセッションを止め（STT Worker は同時に1セッションしか認識しないため。
///    録音中に前面を奪って挿入先を変えないためでもある）、利用者に復旧するか尋ねる。断ったら候補の音声をすべて削除する
/// 3. 復旧を選んだら、候補ごとに `TemporaryAudioRecovery.recover` で音声を戻して認識し直し、ローカルで整形して
///    コピーできるプレビューに出す。元の入力欄は変わっている可能性が高いため、自動では挿入しない（AC-09 と同じ退避）
///
/// - 音声認識が使えない（エンジン未選択）なら尋ねない。音声は残し、保持期限で削除する
/// - 認識し直せなかった音声は残し（`TemporaryAudioRecovery` の方針）、件数だけを知らせる
/// - 読み込み・認識し直し・削除は `TemporaryAudioStoreQueue` の中で、メインスレッドの外で1つずつ行う
/// - 整形はローカル（Raw / Local Basic）だけでネットワークに出ない。入力先が分からないため、スタイル区分は既定にする
@MainActor
final class LaunchAudioRecovery {
  enum Outcome: Hashable, Sendable {
    /// 復旧候補がなかった（整理はした）
    case noCandidates
    /// 音声認識が使えないため尋ねなかった
    case recognizerUnavailable(count: Int)
    /// 利用者が断り、候補の音声を削除した
    case declined(count: Int)
    /// 復旧を試した。`previewed` はプレビューに出した件数、`unrecovered` は戻せずに残した件数
    case attempted(previewed: Int, unrecovered: Int)
    /// セッションが待機中になるのを待つ間に取り消された。音声は残す
    case cancelled
  }

  private let queue: TemporaryAudioStoreQueue
  private let recognizer: (any SpeechRecognizer)?
  private let refiner: any LocalRefiner
  private let refinementMode: RefinementMode
  private let styleResolver: AppStyleResolver
  private let prompt: any AudioRecoveryPrompting
  private let preview: any InsertionPreviewPresenting
  private let gate: any RecoverySessionGate
  private let sleep: @Sendable (Duration) async throws -> Void

  /// - Parameters:
  ///   - gate: 確認と認識の間、新しいセッションを止める
  ///   - sleep: セッションが待機中になるのを待つ間隔の待ち。テストでは待たずに返す
  init(
    queue: TemporaryAudioStoreQueue,
    recognizer: (any SpeechRecognizer)?,
    refiner: any LocalRefiner = LocalBasicRefiner(),
    refinementMode: RefinementMode,
    styleResolver: AppStyleResolver = AppStyleResolver(),
    prompt: any AudioRecoveryPrompting,
    preview: any InsertionPreviewPresenting,
    gate: any RecoverySessionGate,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.queue = queue
    self.recognizer = recognizer
    self.refiner = refiner
    self.refinementMode = refinementMode
    self.styleResolver = styleResolver
    self.prompt = prompt
    self.preview = preview
    self.gate = gate
    self.sleep = sleep
  }

  /// 起動時の整理と復旧候補の取得をキューに頼み、復旧の手順を始める。
  ///
  /// 起動直後のセッションの保存より先に整理するよう、ほかの操作より前に（`AppComposition` の初期化の中で）呼ぶ。
  /// 後から保存したセッションの音声を、復旧候補に含めないため
  @discardableResult
  func start() -> Task<Outcome, Never> {
    let candidates = queue.enqueue { store in
      (try? TemporaryAudioRecovery(store: store).candidates()) ?? []
    }
    return Task { [self] in
      await run(candidates: await candidates.value)
    }
  }

  private func run(candidates: [TemporaryAudioRecoveryCandidate]) async -> Outcome {
    guard !candidates.isEmpty else { return .noCandidates }
    guard let recognizer else { return .recognizerUnavailable(count: candidates.count) }
    // 録音・処理中のセッションが終わるのを待つ
    while !gate.suspendIfIdle() {
      do {
        try await sleep(.milliseconds(500))
      } catch {
        return .cancelled
      }
    }
    defer { gate.resume() }

    guard await prompt.confirmRecovery(count: candidates.count) else {
      let sessions = candidates.map(\.sessionID)
      await queue.enqueue { store in
        for session in sessions {
          try? store.remove(session)
        }
      }.value
      return .declined(count: candidates.count)
    }

    var previewed = 0
    var unrecovered = 0
    for candidate in candidates {
      let result = await queue.enqueue { store in
        await Self.recover(candidate, store: store, recognizer: recognizer)
      }.value
      switch result {
      case .recovered(let text, _, let removed):
        if !removed {
          // 次回の起動時に同じ発話を再び尋ねないよう、削除をやり直す
          let session = candidate.sessionID
          queue.enqueue { store in try? store.remove(session) }
        }
        if show(text) { previewed += 1 }
      case .unrecoverable:
        // 戻せる音声がなかった（形式の違い・壊れ）。音声は削除済みで、知らせることはない
        break
      case .unreadable, .processingFailed, .cancelled:
        unrecovered += 1
      }
    }
    if unrecovered > 0 {
      prompt.reportUnrecovered(count: unrecovered)
    }
    return .attempted(previewed: previewed, unrecovered: unrecovered)
  }

  /// 新しい順に音声を戻し、同じセッションID のまま認識し直す。キューの中（メインスレッドの外）で呼ぶ
  private nonisolated static func recover(
    _ candidate: TemporaryAudioRecoveryCandidate, store: TemporaryAudioStore,
    recognizer: any SpeechRecognizer
  ) async -> TemporaryAudioRecoveryResult<String> {
    await TemporaryAudioRecovery(store: store).recover(
      candidate,
      decode: { try RecordedAudio(decoding: $0) },
      process: { audio, session in try await recognize(audio, session, recognizer) })
  }

  /// ローカルで整形してプレビューに出す。空なら出さない
  private func show(_ text: String) -> Bool {
    let style = styleResolver.style(forBundleID: nil)
    let refined = refiner.refine(RefinementRequest(text: text, mode: refinementMode, style: style))
    guard !refined.isEmpty else { return false }
    preview.showPreview(text: refined, cause: .recoveredAfterRestart)
    return true
  }

  private struct RecognitionFailed: Error {}

  /// 同じセッションID のまま認識し直す。完了しなければ投げる（音声は残る）
  private nonisolated static func recognize(
    _ audio: RecordedAudio, _ session: SessionID, _ recognizer: any SpeechRecognizer
  ) async throws -> String {
    switch await recognizer.recognizeAgain(audio, session: session) {
    case .completed(let text): return text
    case .failed: throw RecognitionFailed()
    case .cancelled: throw CancellationError()
    }
  }
}
