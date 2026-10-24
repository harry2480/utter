import Foundation
import UtterCore

/// アプリの異常終了後の起動時に、一時音声から発話を戻す手順（7章, AC-10）。
///
/// `candidates()` で保持期限を過ぎたものを削除し、残りをセッションごとにまとめて返す。利用者が復旧を選んだら
/// `recover(_:decode:process:)` で、作成時刻が新しい順に読み込み・形式の復元を試し、最初に戻せた音声を
/// `process`（認識のやり直しなど）へ渡す。UtterPersistence は音声の形式と認識に依存しないため、
/// 形式の復元（UtterSpeech の `RecordedAudio(decoding:)`）と認識のやり直しは呼び出し側が渡す。
///
/// 同じストアへの操作は、呼び出し側で1つずつ実行する（`TemporaryAudioStore` と同じ）。
public struct TemporaryAudioRecovery: Sendable {
  public let store: TemporaryAudioStore

  public init(store: TemporaryAudioStore) {
    self.store = store
  }

  /// 起動時の整理（`TemporaryAudioStore.sweep()`）をして、復旧を確認するセッションを返す。
  ///
  /// 同じセッションの音声が複数残っていれば1つにまとめる。並びは、各セッションの最新の音声の作成時刻が新しい順。
  /// 削除できなかったものは次回の整理で再び試すため、ここでは返さない。
  public func candidates() throws(TemporaryAudioStoreError) -> [TemporaryAudioRecoveryCandidate] {
    let recoverable = try store.sweep().recoverable
    // list() は古い順なので、逆にすると新しい順になる。同じセッションの中も新しい順にそろう
    var order: [SessionID] = []
    var records: [SessionID: [TemporaryAudioRecord]] = [:]
    for record in recoverable.reversed() {
      if records[record.sessionID] == nil {
        order.append(record.sessionID)
      }
      records[record.sessionID, default: []].append(record)
    }
    return order.compactMap { session in
      records[session].map { TemporaryAudioRecoveryCandidate(sessionID: session, records: $0) }
    }
  }

  /// `candidate` の音声を新しい順に戻し、最初に戻せたものを `process` へ渡す。
  ///
  /// - 読み込めない・`decode` が失敗するものは飛ばし、次に古いものを試す。保持期限を過ぎたものは試さない
  /// - 読み込めないもの（端末のロック中など）があれば、それより古いものは試さず、あとで試せるよう音声を残して
  ///   `unreadable` を返す。古い音声で復旧すると、新しい音声ごと削除してしまうため
  /// - `process` には `candidate.sessionID` をそのまま渡す。一時音声と状態機械が同じセッションを指すよう
  ///   `SessionID` は使い回す（認識の順序番号は 0 から始まり直す）
  /// - `process` が値を返したら、そのセッションの音声をまとめて削除する（期限切れのものを含む）。
  ///   読み込めたがすべて `decode` に失敗した（または期限切れだった）場合も削除する
  /// - `process` が失敗した場合とキャンセルされた場合は音声を残す。やり直せるよう、削除は保持期限に任せる
  ///
  /// - Parameters:
  ///   - decode: 読み込んだバイト列を音声に戻す。戻せなければ投げる
  ///   - process: 戻した音声とセッションID を受け取り、認識をやり直す。キャンセルされたら `CancellationError` を投げる
  public func recover<Audio, Output>(
    _ candidate: TemporaryAudioRecoveryCandidate,
    isolation: isolated (any Actor)? = #isolation,
    decode: (Data) throws -> Audio,
    process: (Audio, SessionID) async throws -> Output
  ) async -> TemporaryAudioRecoveryResult<Output> {
    var restored: (audio: Audio, record: TemporaryAudioRecord)?
    for record in candidate.records {
      if Task.isCancelled { return .cancelled }
      // 期限切れのものは、復旧を終えたときにセッションごと削除する（キャンセル時に消さないよう、ここでは消さない）
      if store.isExpired(record) { continue }
      let data: Data
      do {
        data = try store.load(record)
      } catch {
        // 端末のロック中（ファイル保護）など、あとで読めるかもしれないものは戻せないと決めない。
        // 古い音声で復旧すると新しい音声ごと削除してしまうため、古いものも試さずに終える。
        // すでに無くなったものは、読めないのではなく試すものがないだけとして扱う
        if FileManager.default.fileExists(atPath: record.url.path) { return .unreadable }
        continue
      }
      guard let audio = try? decode(data) else { continue }
      restored = (audio, record)
      break
    }
    guard let restored else {
      return .unrecoverable(removed: removeAll(candidate.sessionID))
    }
    if Task.isCancelled { return .cancelled }
    let output: Output
    do {
      output = try await process(restored.audio, candidate.sessionID)
    } catch {
      return Task.isCancelled || error is CancellationError ? .cancelled : .processingFailed
    }
    // キャンセルに応じずに値を返した場合も、呼び出し側は結果を使わないため、やり直せるよう音声を残す
    if Task.isCancelled { return .cancelled }
    return .recovered(output, from: restored.record, removed: removeAll(candidate.sessionID))
  }

  private func removeAll(_ session: SessionID) -> Bool {
    (try? store.remove(session)) != nil
  }
}

/// 復旧を確認する1つのセッション（7章, AC-10）
public struct TemporaryAudioRecoveryCandidate: Hashable, Sendable {
  public let sessionID: SessionID
  /// そのセッションの音声。作成時刻が新しい順で、1件以上ある
  public let records: [TemporaryAudioRecord]

  /// 最新の音声の作成時刻
  public var createdAt: Date { records[0].createdAt }
}

// セッションID をログに出さないよう、文字列表現とリフレクションには作成時刻と件数だけを出す。
extension TemporaryAudioRecoveryCandidate: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "TemporaryAudioRecoveryCandidate(createdAt: \(createdAt.timeIntervalSince1970), "
      + "count: \(records.count))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["createdAt": createdAt, "count": records.count])
  }
}

/// 一時音声からの復旧の結果（7章, AC-10）
public enum TemporaryAudioRecoveryResult<Output> {
  /// `record` の音声を戻し、`process` が値を返した。`removed` が `false` なら音声の削除に失敗しており、
  /// 次回の起動時に同じ発話を再び復旧しないよう、呼び出し側で `TemporaryAudioStore.remove(_:)` をやり直す
  case recovered(Output, from: TemporaryAudioRecord, removed: Bool)
  /// どの音声も戻せなかった。`removed` が `false` なら削除に失敗しており、保持期限で削除される
  case unrecoverable(removed: Bool)
  /// それより新しい音声を戻せないうちに、読み込めない音声（端末のロック中など）があった。あとで試せるよう音声は残す
  case unreadable
  /// 音声は戻せたが `process` が失敗した。音声は残す
  case processingFailed
  /// キャンセルされた。音声は残す
  case cancelled
}

extension TemporaryAudioRecoveryResult: Sendable where Output: Sendable {}
extension TemporaryAudioRecoveryResult: Equatable where Output: Equatable {}
extension TemporaryAudioRecoveryResult: Hashable where Output: Hashable {}

// 復旧した値（認識テキストなど）をログに出さないよう、文字列表現とリフレクションには結果の種類だけを出す。
extension TemporaryAudioRecoveryResult: CustomStringConvertible, CustomReflectable {
  public var description: String {
    switch self {
    case .recovered(_, let record, let removed): "recovered(from: \(record), removed: \(removed))"
    case .unrecoverable(let removed): "unrecoverable(removed: \(removed))"
    case .unreadable: "unreadable"
    case .processingFailed: "processingFailed"
    case .cancelled: "cancelled"
    }
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}
