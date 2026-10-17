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
}

/// 挿入前に画面へ出す内容（iOS-05, iAC-04）
public enum SharedResultPreview: Hashable, Sendable {
  /// 待っているセッションの結果がない
  case notFound
  /// 挿入できる。本文を表示し、利用者の明示的な挿入操作を待つ
  case insertable(text: String)
  /// 挿入結果が不明。自動では再挿入せず、本文を見せて再挿入するか利用者に確認する（iOS-IPC-03）
  case needsConfirmation(text: String)
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

// 本文をログに出さないよう、文字列表現には区分と文字数だけを出す。
extension SharedResultPreview: CustomStringConvertible {
  public var description: String {
    switch self {
    case .notFound: "SharedResultPreview.notFound"
    case .insertable(let text): "SharedResultPreview.insertable(length: \(text.count))"
    case .needsConfirmation(let text):
      "SharedResultPreview.needsConfirmation(length: \(text.count))"
    case .notInsertable(let reason): "SharedResultPreview.notInsertable(\(reason))"
    }
  }
}

/// キーボード拡張で、共有結果のプレビューと明示的な挿入を行う（iOS-05, iOS-IPC-03, iAC-04）。
///
/// 挿入の前に `inserting` を比較交換で保存して確保するため、連打・キーボードの再生成・本体アプリとの同時操作でも
/// 1回しか挿入しない。挿入を確認できなければ `insertionUnknown` を記録し、自動では再挿入しない。
/// 挿入後の記録が別プロセスの更新（整理で `insertionUnknown` にされた等）と競合したら、読み直して記録し直す。
public actor SharedResultInsertionCoordinator {
  private let store: SharedResultStore
  private let inserter: any SharedResultTextInserter
  private let now: @Sendable () -> Date

  /// 挿入後の記録で比較交換が競合したときに読み直す回数の上限
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

  /// 待っているセッションの結果を、挿入前に表示する内容にする
  public func preview(sessionID: SessionID) async throws -> SharedResultPreview {
    guard let result = try await store.load(sessionID: sessionID) else {
      return .notFound
    }
    switch result.insertability(for: sessionID, at: now()) {
    case .insertable:
      return .insertable(text: result.text)
    case .needsConfirmation:
      return .needsConfirmation(text: result.text)
    case let other:
      return .notInsertable(other)
    }
  }

  /// 利用者の明示的な挿入操作を受けて挿入する。
  /// - Parameter confirmedReinsertion: 挿入結果が不明な結果を、利用者が確認したうえで挿入し直す場合に `true`
  public func insert(
    sessionID: SessionID, confirmedReinsertion: Bool = false
  ) async throws -> SharedResultInsertionOutcome {
    guard let loaded = try await store.load(sessionID: sessionID) else {
      return .notFound
    }
    var claimed = loaded
    do {
      if confirmedReinsertion {
        try claimed.beginInsertionAfterConfirmation(for: sessionID, at: now())
      } else {
        try claimed.beginInsertion(for: sessionID, at: now())
      }
    } catch {
      return .notInserted(loaded.insertability(for: sessionID, at: now()))
    }

    // 挿入する前に確保する。別の操作が先に確保していれば挿入しない
    do {
      try await store.save(claimed, expectedRevision: loaded.revision)
    } catch SharedResultStoreError.revisionConflict {
      let current = try await store.load(sessionID: sessionID)
      return current.map { .notInserted($0.insertability(for: sessionID, at: now())) } ?? .notFound
    }

    let confirmation = await inserter.insert(claimed.text)
    return try await record(confirmation, for: claimed)
  }

  /// 挿入の結果を記録する。競合したら読み直し、挿入済みの記録を失わないようにする
  private func record(
    _ confirmation: SharedResultInsertionConfirmation, for claimed: SharedResult
  ) async throws -> SharedResultInsertionOutcome {
    var base = claimed
    for _ in 0..<Self.maxRecordAttempts {
      var updated = base
      do {
        switch confirmation {
        case .confirmed:
          try updated.markConsumed(at: now())
        case .unknown:
          try updated.markInsertionUnknown()
        }
      } catch {
        // 読み直した結果がすでに目的の状態か、記録できない状態（ready など）になっている
        return Self.outcome(of: base, confirmation: confirmation)
      }
      guard updated.revision != base.revision else {
        return Self.outcome(of: updated, confirmation: confirmation)
      }
      do {
        try await store.save(updated, expectedRevision: base.revision)
        return Self.outcome(of: updated, confirmation: confirmation)
      } catch SharedResultStoreError.revisionConflict {
        guard let current = try await store.load(sessionID: claimed.sessionID) else {
          // 期限切れなどで削除された。挿入は済んでいるため、再挿入の対象は残っていない
          return confirmation == .confirmed ? .inserted : .insertionUnknown
        }
        base = current
      }
    }
    return .insertionUnknown
  }

  private static func outcome(
    of result: SharedResult, confirmation: SharedResultInsertionConfirmation
  ) -> SharedResultInsertionOutcome {
    switch result.status {
    case .consumed:
      return .inserted
    case .insertionUnknown, .inserting, .ready:
      return confirmation == .confirmed ? .inserted : .insertionUnknown
    }
  }
}
