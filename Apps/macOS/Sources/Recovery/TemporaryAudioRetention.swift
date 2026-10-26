import Foundation
import UtterCore
import UtterPersistence
import UtterSpeech

/// セッションの録音音声を一時保存する、`SessionAudioRetaining` の本番実装（7章, AC-10）。
///
/// - 録音中のチャンクをメモリ上の `RecordedAudio` に溜める（STT Worker の異常終了からの再処理に使う）
/// - 録音が止まったら1回だけ `TemporaryAudioStore` に保存する（アプリの異常終了後の起動時の復旧に使う）。
///   録音中は保存しないため、録音中にアプリが異常終了した録音は戻せない（docs/アーキテクチャ.md「一時音声と再処理」）
/// - セッションが終わったら（成功・キャンセル・失敗のいずれも）メモリ上の音声を手放し、保存した音声を削除する
///
/// 保存・削除は `TemporaryAudioStoreQueue` で頼んだ順に行うため、保存の後に削除が追い越さない。
/// 保存・削除の失敗は記録しない（パスや音声をログに出さない）。残った音声は次回起動時の整理と保持期限で消える。
@MainActor
final class TemporaryAudioRetention: SessionAudioRetaining {
  private let queue: TemporaryAudioStoreQueue
  /// `begin` を受けて、まだ `end` を受けていないセッション（同時に1つまで）
  private var session: SessionID?
  private var audio: RecordedAudio?
  /// チャンクのサンプリング周波数が途中で変わった。そのセッションの音声は再処理・保存に使わない
  private var isInconsistent = false
  private var isRecordingFinished = false

  init(queue: TemporaryAudioStoreQueue) {
    self.queue = queue
  }

  func begin(_ session: SessionID) {
    self.session = session
    audio = nil
    isInconsistent = false
    isRecordingFinished = false
  }

  func append(_ chunk: AudioChunk, to session: SessionID) {
    guard self.session == session, !isRecordingFinished, !isInconsistent else { return }
    do {
      if audio == nil {
        audio = try RecordedAudio(sampleRate: chunk.sampleRate)
      }
      try audio?.append(chunk)
    } catch {
      // 周波数の違うチャンクを混ぜると再生速度が変わるため、途中から欠けた音声を使わずに再処理をあきらめる
      isInconsistent = true
      audio = nil
    }
  }

  func finishRecording(_ session: SessionID) {
    guard self.session == session, !isRecordingFinished else { return }
    isRecordingFinished = true
    guard let audio, audio.sampleCount > 0 else { return }
    queue.enqueue { store in
      _ = try? store.save(audio.encoded(), for: session)
    }
  }

  func recordedAudio(for session: SessionID) -> RecordedAudio? {
    self.session == session ? audio : nil
  }

  func end(_ session: SessionID, completed: Bool) {
    guard self.session == session else { return }
    self.session = nil
    audio = nil
    // 保存していなくても、保存の途中かもしれないため削除を頼む（なければ何もしない）
    queue.enqueue { store in
      try? store.remove(session)
    }
  }
}
