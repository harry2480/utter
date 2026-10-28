import Foundation
import UtterCore

/// キーボード拡張が入力欄へ本文を挿入する口（iOS-05）。`UITextDocumentProxy` を使う実装はキーボード拡張側に置く
public protocol SharedResultTextInserter: Sendable {
  /// 本文を挿入する。挿入できたことを確認できなければ `.unknown` を返す
  func insert(_ text: String) async -> SharedResultInsertionConfirmation
}

/// 挿入を確認できたか
public enum SharedResultInsertionConfirmation: Hashable, Sendable {
  case confirmed
  /// 挿入を試みたが、入力欄に入ったかを確認できない
  case unknown

  /// 挿入の前後でカーソルより前の文脈（`UITextDocumentProxy.documentContextBeforeInput`）を比べて、
  /// 挿入した本文が入力欄に入ったかを判定する（iOS-IPC-03）。
  ///
  /// 文脈は入力欄によって一部しか取れない（現在の行だけ、末尾の数十文字だけなど）ため、
  /// 挿入後の文脈が本文で終わるか、本文が挿入後の文脈で終わる（文脈が本文の末尾だけ）ときに確認できたとみなす。
  /// 文脈が取れない・空・挿入の前後で変わらないときは確認できない。本文・文脈はこの判定にだけ使い、保存・記録しない。
  public init(insertedText text: String, contextBefore: String?, contextAfter: String?) {
    guard let contextAfter, !contextAfter.isEmpty, !text.isEmpty, contextAfter != contextBefore
    else {
      self = .unknown
      return
    }
    self = contextAfter.hasSuffix(text) || text.hasSuffix(contextAfter) ? .confirmed : .unknown
  }
}

/// 挿入前に画面へ出す内容（iOS-05, iAC-04）
public enum SharedResultPreview: Hashable, Sendable {
  /// 待っているセッションの結果がない
  case notFound
  /// 挿入できる。本文と有効期限を表示し、利用者の明示的な挿入操作を待つ
  case insertable(text: String, expiresAt: Date)
  /// 挿入結果が不明。自動では再挿入せず、本文を見せて再挿入するか利用者に確認する（iOS-IPC-03）
  case needsConfirmation(text: String, expiresAt: Date)
  /// 挿入できない（期限切れ・挿入済み・挿入中など）
  case notInsertable(SharedResultInsertability)
}

/// 挿入操作の結果
public enum SharedResultInsertionOutcome: Hashable, Sendable {
  /// 挿入し、挿入済みを記録した
  case inserted
  /// 挿入を試みたが確認できなかった。次の表示では再挿入の確認を出す
  case insertionUnknown
  /// 挿入しなかった
  case notInserted(SharedResultInsertability)
  /// 待っているセッションの結果がない
  case notFound
}

/// 利用者の操作で結果を使えなくした（「消す」「入っていた」）結果（iOS-IPC-01〜03）
public enum SharedResultDismissalOutcome: Hashable, Sendable {
  /// 挿入済みとして記録し、共有テキストを削除した
  case dismissed
  /// 変えなかった（挿入中・挿入結果が不明ではないなど）
  case notDismissed(SharedResultInsertability)
  /// 別の操作との競合が続き、変えなかった。読み直してから操作し直す
  case conflicted
  /// 待っているセッションの結果がない
  case notFound
}

// 本文をログに出さないよう、文字列表現とリフレクションには区分と文字数だけを出す。
extension SharedResultPreview: CustomStringConvertible, CustomReflectable {
  public var description: String {
    switch self {
    case .notFound: "SharedResultPreview.notFound"
    case .insertable(let text, _): "SharedResultPreview.insertable(length: \(text.count))"
    case .needsConfirmation(let text, _):
      "SharedResultPreview.needsConfirmation(length: \(text.count))"
    case .notInsertable(let reason): "SharedResultPreview.notInsertable(\(reason))"
    }
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}

/// キーボード拡張で、共有結果のプレビューと明示的な挿入を行う（iOS-05, iOS-IPC-03, iOS-IPC-05, iAC-04）。
///
/// 挿入の前に `inserting` を比較交換で保存して確保するため、連打・キーボードの再生成・本体アプリとの同時操作でも
/// 1回しか挿入しない。挿入を確認できなければ `insertionUnknown` を記録し、自動では再挿入しない。
/// 挿入後の記録が別プロセスの更新（整理で `insertionUnknown` にされた等）と競合したら、読み直して記録し直す。
/// 挿入済みを記録した結果と、期限切れの結果は削除し、共有テキストを残さない。
/// 利用者が「消す」「入っていた」を選んだ結果も、挿入済みとして記録してから削除し、本体アプリでも使えなくする。
///
/// 前提: 本体アプリは削除したセッションIDで結果を作り直さない（セッションごとに新しい ID を使う）。
public actor SharedResultInsertionCoordinator {
  private let store: SharedResultStore
  private let inserter: any SharedResultTextInserter
  private let now: @Sendable () -> Date

  /// 挿入後の記録と、消す・挿入済みにする操作で、比較交換が競合したときに読み直す回数の上限
  static let maxRecordAttempts = 3

  public init(
    store: SharedResultStore,
    inserter: any SharedResultTextInserter,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.store = store
    self.inserter = inserter
    self.now = now
  }

  /// キーボードの表示時に、不要な結果を整理してから、待つセッションを決める（iOS-04, iOS-06, iOS-IPC-05）。
  ///
  /// キーボードは本体アプリで録音したセッションを知らない（本体アプリへの移動・復帰は手動になりうる）ため、
  /// 保存されている結果のうち作成時刻が最も新しいものを待つ。挿入済みの結果と、壊れた・読めない結果は除く。
  /// 作成時刻が現在より後の結果（端末の時刻が戻った後）は、後から作られた正しい結果を隠さないよう除く。
  /// 挿入先の確認は、プレビューと明示的な挿入操作で利用者が行う（iOS-06）。
  /// - Returns: 待つセッション。結果がなければ `nil`
  /// - Throws: 共有結果の一覧を読めない（共有コンテナに入れない）とき
  public func latestSessionID() async throws -> SessionID? {
    // 整理に失敗しても、残った結果は挿入時の判定で弾かれる。一覧を読めないことは下の一覧で投げる
    let now = now()
    _ = try? await store.cleanUp(at: now)
    var latest: SharedResult?
    for sessionID in try await store.storedSessionIDs() {
      guard let result = try? await store.load(sessionID: sessionID), result.consumedAt == nil,
        result.timeValidity(at: now) != .invalidTimestamp
      else {
        continue
      }
      // 作成時刻が同じなら、一覧の順序に左右されないようセッションIDの順で決める
      if latest.map({
        (result.createdAt, result.sessionID.rawValue.uuidString)
          > ($0.createdAt, $0.sessionID.rawValue.uuidString)
      }) ?? true {
        latest = result
      }
    }
    return latest?.sessionID
  }

  /// 待っているセッションの結果を、挿入前に表示する内容にする。期限切れの結果はこのとき削除する
  public func preview(sessionID: SessionID) async throws -> SharedResultPreview {
    guard let result = try await store.load(sessionID: sessionID) else {
      return .notFound
    }
    switch result.insertability(for: sessionID, at: now()) {
    case .insertable:
      return .insertable(text: result.text, expiresAt: result.expiresAt)
    case .needsConfirmation:
      return .needsConfirmation(text: result.text, expiresAt: result.expiresAt)
    case .expired:
      // 挿入に使えないため、共有テキストを残さない（iOS-IPC-05）。失敗しても本体アプリの整理で消える
      try? await store.delete(sessionID: sessionID)
      return .notInsertable(.expired)
    case let other:
      return .notInsertable(other)
    }
  }

  /// 利用者の明示的な挿入操作を受けて挿入する。
  ///
  /// 投げるのは挿入する前の読み書きに失敗した場合だけで、そのときは挿入していない。
  /// 挿入した後に記録できなくても、投げずに挿入の確認結果に応じた値を返す。
  /// - Parameter confirmedReinsertion: 挿入結果が不明な結果を、利用者が確認したうえで挿入し直す場合に `true`
  public func insert(
    sessionID: SessionID, confirmedReinsertion: Bool = false
  ) async throws -> SharedResultInsertionOutcome {
    let now = now()
    guard let loaded = try await store.load(sessionID: sessionID) else {
      return .notFound
    }
    var claimed = loaded
    do {
      // 確認つきの再挿入でも、結果がそのまま挿入できる状態なら通常の挿入として扱う
      if confirmedReinsertion, loaded.insertability(for: sessionID, at: now) != .insertable {
        try claimed.beginInsertionAfterConfirmation(for: sessionID, at: now)
      } else {
        try claimed.beginInsertion(for: sessionID, at: now)
      }
    } catch .notInsertable(let reason) {
      if reason == .expired {
        // 挿入に使えないため、共有テキストを残さない（iOS-IPC-05）。失敗しても本体アプリの整理で消える
        try? await store.delete(sessionID: sessionID)
      }
      return .notInserted(reason)
    } catch {
      return .notInserted(loaded.insertability(for: sessionID, at: now))
    }

    // 挿入する前に確保する。別の操作が先に確保していれば挿入しない
    do {
      try await store.save(claimed, expectedRevision: loaded.revision)
    } catch SharedResultStoreError.revisionConflict {
      let current = try await store.load(sessionID: sessionID)
      return current.map { .notInserted($0.insertability(for: sessionID, at: now)) } ?? .notFound
    }

    let confirmation = await inserter.insert(claimed.text)
    return await record(confirmation, for: claimed)
  }

  /// 利用者の「消す」操作を受けて、結果を挿入済みとして記録し、共有テキストを削除する（iOS-IPC-01〜03, iOS-IPC-05）。
  ///
  /// 挿入済みと同じ状態にするため、本体アプリの救済画面でもコピーできなくなる。挿入中（猶予時間内）の結果は消さない。
  /// 投げるのは読み書きに失敗した場合だけで、そのときは結果を変えていない。
  public func discard(sessionID: SessionID) async throws -> SharedResultDismissalOutcome {
    try await dismiss(sessionID: sessionID) { result, now in
      try result.markDiscarded(at: now)
    }
  }

  /// 挿入結果が不明な結果を、利用者が「入っていた」と確認したことを受けて、挿入済みとして記録する（iOS-IPC-03）。
  ///
  /// 挿入はしない。挿入結果が不明（猶予時間を過ぎた挿入中を含む）でない結果は変えない。
  /// 投げるのは読み書きに失敗した場合だけで、そのときは結果を変えていない。
  public func confirmInserted(sessionID: SessionID) async throws -> SharedResultDismissalOutcome {
    try await dismiss(sessionID: sessionID) { result, now in
      let insertability = result.insertability(for: sessionID, at: now)
      guard insertability == .needsConfirmation else {
        throw SharedResultError.notInsertable(insertability)
      }
      try result.markConsumed(at: now)
    }
  }

  /// 結果を `consumed` に変えて比較交換で保存し、削除する。競合したら読み直す
  private func dismiss(
    sessionID: SessionID,
    _ markConsumed: (inout SharedResult, Date) throws -> Void
  ) async throws -> SharedResultDismissalOutcome {
    for _ in 0..<Self.maxRecordAttempts {
      guard let loaded = try await store.load(sessionID: sessionID) else {
        return .notFound
      }
      // 読み込んだ後の時刻で判定する
      let now = now()
      var updated = loaded
      do {
        try markConsumed(&updated, now)
      } catch SharedResultError.notInsertable(let reason) {
        return .notDismissed(reason)
      } catch {
        return .notDismissed(loaded.insertability(for: sessionID, at: now))
      }
      do {
        if updated.revision != loaded.revision {
          try await store.save(updated, expectedRevision: loaded.revision)
        }
      } catch SharedResultStoreError.revisionConflict {
        continue
      }
      // 挿入済みを記録できたため、削除に失敗しても本体アプリの整理で消える
      try? await store.delete(sessionID: sessionID)
      return .dismissed
    }
    return .conflicted
  }

  /// 挿入の結果を記録する。挿入はすでに済んでいるため、記録に失敗しても投げずに、挿入の確認結果に応じた値を返す。
  private func record(
    _ confirmation: SharedResultInsertionConfirmation, for claimed: SharedResult
  ) async -> SharedResultInsertionOutcome {
    await store.recordCompletion(
      of: claimed, confirmation: confirmation, maxAttempts: Self.maxRecordAttempts, now: now)
    return confirmation == .confirmed ? .inserted : .insertionUnknown
  }
}

extension SharedResultStore {
  /// `inserting` で確保した結果に、挿入（またはコピー）の結果を記録する（iOS-IPC-03, iOS-IPC-05, iOS-07）。
  ///
  /// 競合したら読み直し、挿入済みの記録を失わないようにする。挿入済みを記録した結果は削除し、共有テキストを残さない。
  /// 挿入・コピーはすでに済んでいるため、記録に失敗しても投げない（残った結果は整理で復旧する）。
  func recordCompletion(
    of claimed: SharedResult,
    confirmation: SharedResultInsertionConfirmation,
    maxAttempts: Int,
    now: @Sendable () -> Date
  ) {
    var base = claimed
    for _ in 0..<maxAttempts {
      var updated = base
      do {
        switch confirmation {
        case .confirmed:
          try updated.markConsumed(at: now())
        case .unknown:
          try updated.markInsertionUnknown()
        }
      } catch {
        // 読み直した結果が、記録できない状態（挿入済みに対する結果不明など）になっている
        return
      }
      do {
        if updated.revision != base.revision {
          try save(updated, expectedRevision: base.revision)
        }
        if case .consumed = updated.status {
          // 失敗しても本体アプリの整理で消える
          try? delete(sessionID: claimed.sessionID)
        }
        return
      } catch SharedResultStoreError.revisionConflict {
        guard let current = try? load(sessionID: claimed.sessionID) else {
          // 期限切れなどで削除された、または読めない。挿入は済んでいる
          return
        }
        base = current
      } catch {
        return
      }
    }
  }
}
