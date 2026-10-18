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
  /// コピーし、コピー済みを記録した
  case copied
  /// コピーしなかった（期限切れ・挿入済み・挿入中など）
  case notCopied(SharedResultInsertability)
  /// 結果がない
  case notFound
}

// 本文をログに出さないよう、文字列表現には区分と文字数だけを出す。
extension SharedResultRescueState: CustomStringConvertible {
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
/// - コピーする前にコピー済み（`consumed`）を比較交換で保存して確保し、キーボードの挿入と二重にしない（iOS-IPC-03）。
///   コピーした結果は共有テキストを削除する。本文はクリップボードに残るため、何度でも貼り付けられる
public actor SharedResultRescueCoordinator {
  private let store: SharedResultStore
  private let copier: any SharedResultTextCopier
  private let now: @Sendable () -> Date

  /// コピーの確保で比較交換が競合したときに読み直す回数の上限
  static let maxClaimAttempts = 3

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
  public func items() async throws -> SharedResultRescueList {
    let now = now()
    var items: [SharedResultRescueItem] = []
    var unavailableCount = 0
    for sessionID in try await store.storedSessionIDs() {
      let loaded: SharedResult?
      do {
        loaded = try await store.load(sessionID: sessionID)
      } catch SharedResultStoreError.fileAccessDenied {
        unavailableCount += 1
        continue
      } catch {
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
  public func copy(sessionID: SessionID) async throws -> SharedResultCopyOutcome {
    let now = now()
    for _ in 0..<Self.maxClaimAttempts {
      guard let loaded = try await store.load(sessionID: sessionID) else {
        return .notFound
      }
      var claimed = loaded
      do {
        try claimed.markCopied(at: now)
      } catch .notInsertable(let reason) {
        if reason == .expired || reason == .consumed {
          // 共有テキストを残さない（iOS-IPC-05）。失敗しても本体アプリの整理で消える
          try? await store.delete(sessionID: sessionID)
        }
        return .notCopied(reason)
      } catch {
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
      // コピーした共有テキストを残さない（iOS-IPC-05）。失敗しても本体アプリの整理で消える
      try? await store.delete(sessionID: sessionID)
      return .copied
    }
    guard let current = try await store.load(sessionID: sessionID) else {
      return .notFound
    }
    return .notCopied(current.insertability(for: sessionID, at: now))
  }

  /// 結果を救済画面の状態にする。本文はコピーしてよい状態のときだけ含める
  static func state(of result: SharedResult, at now: Date) -> SharedResultRescueState {
    switch result.insertability(for: result.sessionID, at: now) {
    case .insertable:
      return .notInserted(text: result.text)
    case .needsConfirmation:
      // 挿入結果不明は時刻を見ずに判定されるため、期限を確かめる
      if now < result.createdAt {
        return .invalidTimestamp
      }
      return now < result.expiresAt ? .insertionUnknown(text: result.text) : .expired
    case .inProgress:
      return .inserting
    case .consumed:
      return .inserted
    case .expired:
      return .expired
    case .invalidTimestamp:
      return .invalidTimestamp
    case .sessionMismatch:
      // 自分のセッションIDで判定するため起こらない。安全側として本文は出さない
      return .invalidTimestamp
    }
  }
}
