import Foundation
import UtterCore

/// 本体アプリが本文をクリップボードへコピーする口（iOS-07）。`UIPasteboard` を使う実装は本体アプリ側に置く。
///
/// 実装では、他の端末へ同期しない（`localOnly`）・期限つきでコピーすることを推奨する。
public protocol SharedResultTextCopier: Sendable {
  func copy(_ text: String) async
}

/// 救済画面で出す結果の状態（iOS-07）。本文は、コピーしてよい状態のときだけ持つ
public enum SharedResultRescueState: Hashable, Sendable {
  /// 未挿入。本文を確認・コピーできる
  case notInserted(text: String)
  /// 挿入を試みたが結果が不明。すでに入力欄に入っている可能性を示したうえで、確認・コピーできる
  case insertionUnknown(text: String)
  /// キーボードが挿入中（猶予時間内）。二重にならないようコピーさせない
  case inserting
  /// 挿入済み、またはコピー済み。共有テキストは削除するため本文は出さない（iOS-IPC-05）
  case inserted
  /// 期限切れ。共有テキストは削除するため本文は出さない（iOS-IPC-05）
  case expired
  /// 端末の時刻が作成時より前で、期限を判定できない。安全側として本文は出さない
  case invalidTimestamp
}

/// 救済画面で出す1件の結果（iOS-07）
public struct SharedResultRescueItem: Hashable, Sendable {
  public let sessionID: SessionID
  public let createdAt: Date
  public let expiresAt: Date
  public let state: SharedResultRescueState

  public init(
    sessionID: SessionID, createdAt: Date, expiresAt: Date, state: SharedResultRescueState
  ) {
    self.sessionID = sessionID
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.state = state
  }
}

/// 救済画面で出す一覧（iOS-07）
public struct SharedResultRescueList: Hashable, Sendable {
  /// 作成が新しい順
  public let items: [SharedResultRescueItem]
  /// 端末のロック中（ファイル保護）などで読めなかった結果の数。ロックの解除を案内する（iOS-IPC-05）
  public let unavailableCount: Int

  public init(items: [SharedResultRescueItem], unavailableCount: Int) {
    self.items = items
    self.unavailableCount = unavailableCount
  }
}

/// コピー操作の結果（iOS-07）
public enum SharedResultCopyOutcome: Hashable, Sendable {
  /// コピーした
  case copied
  /// 別の操作との競合が続き、コピーしなかった。読み直してから操作し直す
  case conflicted
  /// コピーしなかった（期限切れ・挿入済み・挿入中など）
  case notCopied(SharedResultInsertability)
  /// 結果がない
  case notFound
}

// 本文をログに出さないよう、文字列表現とリフレクションには区分と文字数だけを出す。
extension SharedResultRescueState: CustomStringConvertible, CustomReflectable {
  public var customMirror: Mirror {
    Mirror(self, children: ["description": description], displayStyle: .enum)
  }

  public var description: String {
    switch self {
    case .notInserted(let text): "SharedResultRescueState.notInserted(length: \(text.count))"
    case .insertionUnknown(let text):
      "SharedResultRescueState.insertionUnknown(length: \(text.count))"
    case .inserting: "SharedResultRescueState.inserting"
    case .inserted: "SharedResultRescueState.inserted"
    case .expired: "SharedResultRescueState.expired"
    case .invalidTimestamp: "SharedResultRescueState.invalidTimestamp"
    }
  }
}

// 本文をログに出さないよう、リフレクションでも状態の文字列表現だけを出す。
extension SharedResultRescueItem: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "SharedResultRescueItem(state: \(state))"
  }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "sessionID": sessionID, "createdAt": createdAt, "expiresAt": expiresAt,
        "state": state.description,
      ])
  }
}

/// 本体アプリで、キーボードから挿入できなかった結果を確認・コピーする救済導線（iOS-07）。
///
/// アプリへの復帰に失敗した・キーボードを表示できなかった・挿入結果が不明になった場合に、
/// 共有結果を本体アプリで確認し、クリップボードへコピーできるようにする。コピーは主経路ではない。
/// - 本文を出すのは期限内の未挿入・挿入結果不明の結果だけ。期限切れ・挿入済みの結果は本文を出さずに状態だけを示し、
///   共有テキストを削除する（iOS-IPC-05）
/// - コピーはキーボードの挿入と同じ二段階で行う。まず `inserting` を比較交換で保存して確保し（二重にしない, iOS-IPC-03）、
///   コピーした後に `consumed` を記録して共有テキストを削除する。コピーの途中でアプリが終了しても、
///   確保した結果は整理（`SharedResultStore.cleanUp(at:)`）で挿入結果不明に戻り、もう一度救済できる（iOS-IPC-06）。
///   本文はクリップボードに残るため、何度でも貼り付けられる
public actor SharedResultRescueCoordinator {
  private let store: SharedResultStore
  private let copier: any SharedResultTextCopier
  private let now: @Sendable () -> Date

  /// 比較交換が競合したときに読み直す回数の上限（確保と記録のそれぞれ）
  static let maxAttempts = 3

  public init(
    store: SharedResultStore,
    copier: any SharedResultTextCopier,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.store = store
    self.copier = copier
    self.now = now
  }

  /// 保存されている結果を、救済画面に出す一覧にする。期限切れ・挿入済みの結果はこのとき削除する。
  ///
  /// 壊れた結果は一覧に出さない（本体アプリの整理で削除される）。
  /// 端末のロック中などで読めない結果は、件数だけを返す。
  public func items() async throws -> SharedResultRescueList {
    let now = now()
    var items: [SharedResultRescueItem] = []
    var unavailableCount = 0
    for sessionID in try await store.storedSessionIDs() {
      let loaded: SharedResult?
      do {
        loaded = try await store.load(sessionID: sessionID)
      } catch SharedResultStoreError.corruptedResult {
        continue
      } catch {
        unavailableCount += 1
        continue
      }
      guard let result = loaded else { continue }
      let state = Self.state(of: result, at: now)
      if state == .expired || state == .inserted {
        // 共有テキストを残さない（iOS-IPC-05）。失敗しても本体アプリの整理で消える
        try? await store.delete(sessionID: sessionID)
      }
      items.append(
        SharedResultRescueItem(
          sessionID: sessionID, createdAt: result.createdAt, expiresAt: result.expiresAt,
          state: state))
    }
    items.sort { $0.createdAt > $1.createdAt }
    return SharedResultRescueList(items: items, unavailableCount: unavailableCount)
  }

  /// 利用者の操作を受けて、結果の本文をクリップボードへコピーする。
  ///
  /// 投げるのはコピーする前の読み書きに失敗した場合だけで、そのときはコピーしていない。
  /// コピーした後に記録できなくても投げない（確保した結果は整理で挿入結果不明に戻る）。
  public func copy(sessionID: SessionID) async throws -> SharedResultCopyOutcome {
    for _ in 0..<Self.maxAttempts {
      guard let loaded = try await store.load(sessionID: sessionID) else {
        return .notFound
      }
      // 読み込んだ後の時刻で判定する
      let now = now()
      var claimed = loaded
      do {
        switch Self.copyability(of: loaded, at: now) {
        case .insertable:
          try claimed.beginInsertion(for: sessionID, at: now)
        case .needsConfirmation:
          // コピーは利用者の明示的な操作のため、挿入結果不明でも確認済みとして確保する
          try claimed.beginInsertionAfterConfirmation(for: sessionID, at: now)
        case let reason:
          if reason == .expired || reason == .consumed {
            // 共有テキストを残さない（iOS-IPC-05）。失敗しても本体アプリの整理で消える
            try? await store.delete(sessionID: sessionID)
          }
          return .notCopied(reason)
        }
      } catch {
        // 上の判定で確かめているため起こらない。安全側としてコピーしない
        return .notCopied(loaded.insertability(for: sessionID, at: now))
      }

      // コピーする前に確保する。キーボードが先に挿入を始めていればコピーしない
      do {
        try await store.save(claimed, expectedRevision: loaded.revision)
      } catch SharedResultStoreError.revisionConflict {
        // 整理で挿入結果不明にされた場合などは、読み直せばコピーできる
        continue
      }

      await copier.copy(claimed.text)
      await store.recordCompletion(
        of: claimed, confirmation: .confirmed, maxAttempts: Self.maxAttempts, now: self.now)
      return .copied
    }
    return .conflicted
  }

  /// コピーしてよいかを判定する。
  ///
  /// `insertability(for:at:)` に加えて、挿入結果不明（猶予時間を過ぎた挿入中を含む）の期限と、
  /// 挿入を始めた時刻より時刻が戻っていないかを確かめる。
  static func copyability(of result: SharedResult, at now: Date) -> SharedResultInsertability {
    let insertability = result.insertability(for: result.sessionID, at: now)
    guard insertability == .needsConfirmation else {
      return insertability
    }
    if case .inserting(let startedAt) = result.status, now < startedAt {
      return .invalidTimestamp
    }
    return result.timeValidity(at: now) ?? .needsConfirmation
  }

  /// 結果を救済画面の状態にする。本文はコピーしてよい状態のときだけ含める
  static func state(of result: SharedResult, at now: Date) -> SharedResultRescueState {
    switch copyability(of: result, at: now) {
    case .insertable:
      return .notInserted(text: result.text)
    case .needsConfirmation:
      return .insertionUnknown(text: result.text)
    case .inProgress:
      return .inserting
    case .consumed:
      return .inserted
    case .expired:
      return .expired
    case .invalidTimestamp:
      return .invalidTimestamp
    case .sessionMismatch:
      // 結果自身のセッションIDで判定するため起こらない。起きた場合も安全側として本文は出さず、削除もしない
      assertionFailure("結果自身のセッションIDで判定したのに sessionMismatch になった")
      return .invalidTimestamp
    }
  }
}
